# @summary Adds cron service always run control
#
# Adds cron service always run control
#
# @example
#   include lsys::cron::service
class lsys::cron::service (
  Boolean $enable_monit = false,
) {
  if $enable_monit {
    monit::check { 'cron':
      content => template('lsys/cron/monit.epp'),
    }
  }

  if  $facts['os']['name'] in ['RedHat', 'CentOS'] and
      $facts['os']['release']['major'] in ['7', '8'] {
    systemd::dropin_file { 'crond.service.d/override.conf':
      filename => 'override.conf',
      unit     => 'crond.service',
      content  => file('lsys/cron/systemd.conf'),
    }
  }
}
