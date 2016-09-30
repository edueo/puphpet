class puphpet::php (
  $php     = $puphpet::params::hiera['php'],
  $mailhog = $puphpet::params::hiera['mailhog'],
) {

  include ::php::params
  include ::puphpet::php::params

  class { 'puphpet::php::settings':
    version_string => $php['settings']['version'],
  }

  $version       = $puphpet::php::settings::version
  $base_ini      = $puphpet::php::settings::base_ini
  $package       = $puphpet::php::settings::fpm_package
  $package_devel = $puphpet::php::settings::package_devel
  $service       = $puphpet::php::settings::service

  class { 'puphpet::php::repos':
    php_version => $version,
  }

  if ! defined(Service[$service]) {
    service { $service:
      ensure     => 'running',
      enable     => true,
      hasrestart => true,
      hasstatus  => true,
      require    => Package[$package]
    }

    class { 'php':
      package             => $package,
      package_devel       => $package_devel,
      service             => $service,
      version             => 'present',
      service_autorestart => false,
      config_file         => $base_ini,
    }

    if ! defined(Package[$package_devel]) {
      package { $package_devel :
        ensure  => present,
        require => Class['php']
      }
    }
  }

  # config file could contain no fpm_ini key
  $fpm_inis = array_true($php, 'fpm_ini') ? {
    true    => $php['fpm_ini'],
    default => { }
  }

  $fpm_inis_merged = merge($fpm_inis, {
    'pid' => $puphpet::php::settings::pid_file,
  })

  each( $fpm_inis_merged ) |$name, $value| {
    puphpet::php::fpm::ini { "${name}: ${value}":
      fpm_version     => $version,
      entry           => $name,
      value           => $value,
      php_fpm_service => $service
    }
  }

  # config file could contain no fpm_pools key
  $fpm_pools = array_true($php, 'fpm_pools') ? {
    true    => $php['fpm_pools'],
    default => { }
  }

  each( $fpm_pools ) |$pKey, $pool_settings| {
    $pool = $fpm_pools[$pKey]

    # pool could contain no ini key
    $ini_hash = array_true($pool, 'ini') ? {
      true    => $pool['ini'],
      default => { }
    }

    each( $ini_hash ) |$name, $value| {
      $pool_name = array_true($ini_hash, 'prefix') ? {
        true    => $ini_hash['prefix'],
        default => $pKey
      }

      if $name != 'prefix' {
        puphpet::php::fpm::pool_ini { "${pool_name}/${name}: ${value}":
          fpm_version     => $version,
          pool_name       => $pool_name,
          entry           => $name,
          value           => $value,
          php_fpm_service => $service
        }
      }
    }
  }

  $php_modules = $php['modules']['php'];
  each( $php_modules ) |$name| {
    if ! defined(Puphpet::Php::Module[$name]) {
      puphpet::php::module { $name:
        service_autorestart => true,
        notify              => Service[$service],
      }
    }
  }

  each( $php['modules']['pear'] ) |$name| {
    if ! defined(Puphpet::Php::Pear[$name]) {
      puphpet::php::pear { $name:
        service_autorestart => true,
        notify              => Service[$service],
      }
    }
  }

  each( $php['modules']['pecl'] ) |$name| {
    if ! defined(Puphpet::Php::Extra_repos[$name]) {
      puphpet::php::extra_repos { $name:
        before => Puphpet::Php::Pecl[$name],
      }
    }

    if ! defined(Puphpet::Php::Pecl[$name]) {
      puphpet::php::pecl { $name:
        service_autorestart => true,
        notify              => Service[$service],
      }
    }
  }

  $php_inis = merge({
    'cgi.fix_pathinfo' => 1,
  }, $php['ini'])

  each( $php_inis ) |$key, $value| {
    if is_array($value) {
      each( $php_inis[$key] ) |$inner_key, $inner_value| {
        puphpet::php::ini { "${key}_${$inner_key}":
          entry       => "CUSTOM_${$inner_key}/${key}",
          value       => $inner_value,
          php_version => $version,
          webserver   => $service,
          notify      => Service[$service],
        }
      }
    } else {
      puphpet::php::ini { $key:
        entry       => "CUSTOM/${key}",
        value       => $value,
        php_version => $version,
        webserver   => $service,
      }
    }
  }

  if array_true($php_inis, 'session.save_path') {
    $session_save_path = $php_inis['session.save_path']

    # Handles URLs like tcp://127.0.0.1:6379
    # absolute file paths won't have ":"
    if ! (':' in $session_save_path) and $session_save_path != '/tmp' {
      exec { "mkdir -p ${session_save_path}" :
        creates => $session_save_path,
        notify  => Service[$service],
      }

      if ! defined(File[$session_save_path]) {
        file { $session_save_path:
          ensure  => directory,
          owner   => 'www-data',
          group   => 'www-data',
          mode    => '0775',
          require => Exec["mkdir -p ${session_save_path}"],
        }
      }

      exec { 'set php session path owner/group':
        creates => '/.puphpet-stuff/php-session-path-owner-group',
        command => "chown www-data ${session_save_path} && \
                    chgrp www-data ${session_save_path} && \
                    touch /.puphpet-stuff/php-session-path-owner-group",
        require => [
          File[$session_save_path],
          Package[$package]
        ],
      }
    }
  }

  if array_true($php, 'composer') and ! defined(Class['puphpet::php::composer']) {
    class { 'puphpet::php::composer':
      php_package   => $puphpet::php::settings::cli_package,
      composer_home => $php['composer_home'],
    }
  }

  # Usually this would go within the library that needs it  (MailHog)
  # but the values required are sufficiently complex that it's easier to
  # add here
  if array_true($mailhog, 'install')
    and ! defined(Puphpet::Php::Ini['sendmail_path'])
  {
    puphpet::php::ini { 'sendmail_path':
      entry       => 'CUSTOM/sendmail_path',
      value       => "${mailhog['settings']['path']} sendmail foo@example.com",
      php_version => $version,
      webserver   => $service,
      notify      => Service[$service],
    }
  }

  if $version == '70' and $::osfamily == 'redhat' {
    exec { 'Fix pid_file path':
      command => "perl -p -i -e 's#/var/run/php-fpm/php-fpm.pid#/var/run/php-fpm.pid#gi' /etc/init.d/php-fpm",
      unless  => "grep -x '/var/run/php-fpm.pid' /etc/init.d/php-fpm",
      path    => [ '/bin/', '/sbin/', '/usr/bin/', '/usr/sbin/' ],
      notify  => Service[$service],
    }
  }

  if array_true($puphpet::params::hiera['xdebug'], 'install') {
    class { 'puphpet::php::xdebug::install': }
  }

}
