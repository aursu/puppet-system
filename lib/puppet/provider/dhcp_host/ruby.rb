require 'erb'
require 'ipaddr'

Puppet::Type.type(:dhcp_host).provide(:ruby, parent: Puppet::Provider) do
  DHCP_KEYS = [:mac, :ip, :name, :hostname, :group, :content].freeze

  # Need this to create getter/setter methods automagically
  # This command creates methods that return @property_hash[:value]
  mk_resource_methods

  def create
    @property_hash[:ensure] = :present
  end

  def destroy
    @property_hash[:ensure] = :absent
  end

  def dhcp_data
    return @dhcp if @dhcp

    target = @resource[:target] || '/etc/dhcp/dhcpd.hosts'
    hostname = @resource[:name]

    # lookup Hash for entities with :name or :hostname equal to
    # current @resource[:name]
    dhcp =  dhcp_config_data(target)
            .map { |_k, v| [v, v[:name], v[:hostname]] }
            .select { |d| d.include?(hostname) }
            .map { |d| [hostname, d[0]] }.to_h

    # return empty Hash if nothing found in DHCP config file
    return @dhcp = {} if dhcp.empty?
    @dhcp = dhcp[hostname]
  end

  # Read ENC data for given hostname
  # @api public
  # @return [Hash]
  def enc_data
    return @enc if @enc

    hostname = @resource[:name]

    Dir.glob("/var/lib/pxe/enc/#{hostname}.{eyaml,yaml,yml}").each do |file_name|
      @enc ||= self.class.enc_data(file_name)
    end

    # if file does not exists - set to only-hostname Hash and return
    @enc ||= { hostname: hostname }
  end

  # Generate PXE data based on read ENC data
  # @api public
  # @return [Hash]
  def pxe_data
    @pxe ||= self.class.pxe_data(enc_data)
  end

  # Generate DHCP host declaration based on provided PXE data
  # @api public
  # @return [String]
  def host_content(pxe)
    self.class.host_content(pxe)
  end

  def validate_ip(ip)
    self.class.validate_ip(ip)
  end

  def validate_mac(mac)
    self.class.validate_mac(mac)
  end

  def validate_domain(dom)
    self.class.validate_domain(dom)
  end

  def dhcp_config_data(file_name)
    self.class.dhcp_config_data(file_name)
  end

  def self.instances
    instances = []

    # read ENC data
    Dir.glob('/var/lib/pxe/enc/*.{eyaml,yaml,yml}').each do |file_name|
      enc = enc_data(file_name)
      pxe = pxe_data(enc)

      hash = instance_hash(pxe)

      next unless hash

      instances << new(hash)

      next unless pxe[:ip_map]

      pxe[:ip_map]
        .map { |m| instance_hash(m) }.compact
        .each do |next_map|
          instances << new(next_map)
        end
    end

    instances
  end

  private

  def self.dhcp_config_data(file_name)
    return @dhcp_hosts[file_name] if @dhcp_hosts && @dhcp_hosts[file_name]

    @dhcp_hosts = {} unless @dhcp_hosts
    @dhcp_hosts[file_name] = {}

    host = {}
    if File.exist?(file_name)
      File.open(file_name).each do |line|
        line.strip!

        if %r{^host (?<name>\S+) \{$} =~ line
          host = { name: name }
          next
        end

        next unless host.include?(:name)

        if %r{^hardware ethernet (?<mac>\S+);$} =~ line
          host[:mac] = mac
        elsif %r{^fixed-address (?<ip>\S+);$} =~ line
          host[:ip] = ip
        elsif %r{^option host-name "(?<hostname>\S+)";$} =~ line
          host[:hostname] = hostname
        elsif %r{^\}$} =~ line
          # hostname is more preferable then host declaration name
          hostname = host[:hostname] || host[:name]
          # store host record
          @dhcp_hosts[file_name][hostname] = host
          # reset loop
          host = {}
        end
      end
    end

    @dhcp_hosts[file_name]
  end

  def self.instance_hash(pxe)
    return nil unless pxe[:content]

    hash = pxe.select { |k, _v| DHCP_KEYS.include?(k) }

    hash[:ensure] = :present
    hash[:provider] = name

    hash
  end

  def self.enc_data(file_name)
    data = File.read(file_name)
    enc = YAML.safe_load(data).map { |k, v| [k.to_sym, v] }.to_h

    # Added support for parameter hostname inside ENC file
    # If this parameter is valid domain name (FQDN format) then file name could
    # be arbitrary
    hostname = enc[:hostname]
    if hostname
      enc.delete(:hostname) unless validate_domain(hostname)
    end

    # If ENC file name contains valid domain name (in form <hostname>.yaml)
    # it would be used for PXE/DHCP settings but ENC parameter `hostname`
    # has  higher priority
    hostname = %r{(?<hostname>[^/]+)\.e?ya?ml$}.match(file_name.downcase)[:hostname]
    enc[:hostname] ||= hostname if validate_domain(hostname)

    # `hostname` is mandatory - ignore ENC if valid hostname not found
    return nil unless enc[:hostname]
    enc
  end

  # @param enc [Hash] host data from ENC catalog
  # @return [Hash] hash of host parameters for dhcp_host resource initialization
  #                or an empty hash if we failed to parse ENC
  # @api private
  def self.pxe_data(enc)

    # return empty PXE data if ENC was not provided
    return {} if enc.nil? || enc.empty?

    pxe = {}

    # `mac` and `ip` are mandatory parameters for PXE
    if enc.include?(:pxe) && enc[:pxe].is_a?(Hash)
      pxe = enc[:pxe].map { |k, v| [k.to_sym, v] }.to_h
    end

    # allow to use direct `mac` and `ip` parameters (but those inside `pxe` section
    # have higher priority).
    pxe[:mac] ||= enc[:mac]
    pxe[:ip] ||= enc[:ip]

    pxe[:name] = enc[:hostname].downcase
    pxe[:hostname] = enc[:hostname].downcase

    # validation
    mac = pxe.delete(:mac) unless validate_mac(pxe[:mac])
    ip = pxe.delete(:ip) unless validate_ip(pxe[:ip])
    if ip || mac
      warning _('IP Address (%{ip}) and/or MAC Address (%{mac}) are not valid') %
              { ip: ip, mac: mac }
    end

    # IP mapping if any specified
    #
    # ip_map is Array of network MAC to IP mapping for DHCP client host
    # Element with index 0 is PXE interface
    ip_map = []
    if pxe[:mac] && pxe[:ip]
      # default DHCP group for PXE interface
      pxe[:group] ||= 'pxe'

      # translate
      pxe[:mac].downcase!.tr!('-', ':')
      pxe[:group].downcase!.gsub!(%r{[^a-z0-9]}, '_')

      # it is required to support IP mapping
      # pxe key could contain mapping for up to 9 network interfaces, e.g.
      # pxe:
      #   mac1: xx:xx:xx:xx:xx:xx
      #   ip1: XX.XX.XX.XX
      #   group1: vlanXXX
      (0..9).each do |i|
        j = (i > 0) ? i : nil # rubocop:disable Style/NumericPredicate
        map_keys = ["mac#{j}", "ip#{j}", "group#{j}"].map(&:to_sym)
        next_map = [:mac, :ip, :group].zip(map_keys.map { |k| pxe[k] }).to_h
        hostname, _domain = pxe[:name].split('.', 2)

        # we are strict: if either mac<N> or ip<N> missed - ignore any
        # other mac<N+1> or ip<N+1>
        break unless validate_mac(next_map[:mac]) && validate_ip(next_map[:ip])

        next_map[:group] ||= 'default'
        next_map[:mac].downcase!.tr!('-', ':')
        next_map[:group].downcase!.gsub!(%r{[^a-z0-9]}, '_')
        next_map[:name] = "#{hostname}-eth#{i}"
        next_map[:content] = host_content(next_map)

        ip_map[i] = next_map
      end
    end

    pxe.reject! { |k, v| !DHCP_KEYS.include?(k) || v.nil? }

    pxe[:content] = host_content(pxe)
    pxe[:ip_map] = ip_map unless ip_map.empty?

    pxe
  end

  def self.host_content(pxe)
    [:name, :mac, :ip].each do |k|
      return nil unless pxe[k]
    end

    if pxe[:group] == 'pxe'
      return nil unless pxe[:hostname]
    end

    block_name = pxe[:name]
    mac        = pxe[:mac]
    ip         = pxe[:ip]
    hostname   = pxe[:hostname]

    ERB.new(<<-EOF, nil, '<>').result(binding).strip
  host <%= block_name %> {
    hardware ethernet <%= mac %>;
    fixed-address <%= ip %>;
<% if hostname %>
    option host-name "<%= hostname %>";
<% end %>
  }
EOF
  end

  def self.validate_ip(ip)
    return nil unless ip
    IPAddr.new(ip)
  rescue ArgumentError
    nil
  end

  def self.validate_mac(mac)
    return nil unless mac
    %r{^([a-f0-9]{2}[:-]){5}[a-f0-9]{2}$} =~ mac.downcase
  end

  def self.validate_domain(dom)
    return nil unless dom
    %r{^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$} =~ dom.downcase
  end
end
