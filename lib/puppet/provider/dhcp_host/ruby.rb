require 'erb'

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

  def dhcp_config_data(file_name)
    return @dhcp_hosts if @dhcp_hosts

    @dhcp_hosts = {}

    host = {}
    if File.exist?(file_name)
      File.open(file_name).each do |line|
        line.strip!
        # rubocop:disable Performance/RegexpMatch
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
          @dhcp_hosts[host[:hostname]] = host if host.include?(:hostname)
          host = {}
        end
        # rubocop:enable Performance/RegexpMatch
      end
    end
    @dhcp_hosts
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

  # Read ENC data from given
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

  def pxe_data
    @pxe ||= self.class.pxe_data(enc_data)
  end

  def host_content(pxe)
    self.class.host_content(pxe)
  end

  def self.instances
    instances = []

    # read ENC data
    Dir.glob('/var/lib/pxe/enc/*.{eyaml,yaml,yml}').each do |file_name|
      enc = enc_data(file_name)
      pxe = pxe_data(enc)

      instance_hash = pxe.select { |k, _v| DHCP_KEYS.include?(k) }

      next unless instance_hash[:content]

      instance_hash[:ensure] = :present
      instance_hash[:provider] = name

      instances << new(instance_hash)
    end

    instances
  end

  private

  def self.enc_data(file_name)
    data = File.read(file_name)
    enc = YAML.safe_load(data).map { |k, v| [k.to_sym, v] }.to_h

    enc[:hostname] = %r{(?<hostname>[^/]+)\.e?ya?ml$}.match(file_name)[:hostname]

    enc
  end

  # @param enc [Hash] host data from ENC catalog
  # @return [Hash] hash of host parameters for dhcp_host resource initialization
  #                or an empty hash if we failed to parse
  # @api private
  def self.pxe_data(enc)
    # it is required to support IP mapping
    # pxe key could contain mapping for up to 9 network interfaces, e.g.
    # pxe:
    #   mac1: xx:xx:xx:xx:xx:xx
    #   ip1: XX.XX.XX.XX
    #   group1: vlanXXX
    map_keys =  (1..9)
                .map { |i| ["ip#{i}", "mac#{i}", "group#{i}"] }
                .flatten
                .map { |k| k.to_sym }

    # mac  and ip are  mandatory parameters in ENC
    pxe = {}
    if enc.include?(:pxe) && enc[:pxe].is_a?(Hash)
      pxe = enc[:pxe].map { |k, v| [k.to_sym, v] }.to_h
    end

    ip_map = pxe.select { |k, _v| map_keys.include?(k) }

    # allow to use direct mac, ip parameters (but once inside "pxe" section
    # have higher priority).
    pxe[:mac] ||= enc[:mac]
    pxe[:ip] ||= enc[:ip]

    pxe[:name] = enc[:hostname]
    pxe[:hostname] = enc[:hostname]

    pxe.reject! { |k, v| !DHCP_KEYS.include?(k) || v.nil? }

    pxe[:content] = host_content(pxe)
    pxe[:ip_map] = ip_map unless ip_map.empty?

    pxe
  end

  def self.host_content(pxe)
    [:name, :mac, :ip, :hostname].each do |k|
      return nil unless pxe.include?(k)
    end

    name     = pxe[:name]
    mac      = pxe[:mac]
    ip       = pxe[:ip]
    hostname = pxe[:hostname]

    ERB.new(<<-EOF).result(binding).strip
host <%= name %> {
  hardware ethernet <%= mac %>;
  fixed-address <%= ip %>;
  option host-name "<%= hostname %>";
}
EOF
  end
end
