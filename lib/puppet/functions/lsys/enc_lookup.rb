require 'yaml'

Puppet::Functions.create_function(:'lsys::enc_lookup') do
  dispatch :enc_lookup do
    param 'Stdlib::Fqdn', :hostname
  end

  def enc_lookup(hostname)
    node_terminus = Puppet.settings[:node_terminus]
    if node_terminus == 'exec'
      external_nodes = Puppet.settings[:external_nodes]

      output = Puppet::Util::Execution.execute("#{external_nodes} #{hostname}", failonfail: false)
      output.strip!

      YAML.safe_load(output)
    else
      {}
    end
  end
end
