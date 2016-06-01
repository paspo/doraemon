#!/bin/perl

use Mojolicious::Lite;
use Config::IniFiles;
use Net::Ping;
use Net::ARP;
use esmith::DB::db;
use esmith::ConfigDB;


use Data::Dumper;



# TODO: percorso doraemon.ini
my $cfg = Config::IniFiles->new( -file => "doraemon.ini" );


get '/' => {text => 'Go away!'};

get '/domain' => sub {
	my $domainfile = $cfg->val('Files', 'Domain');
# TODO: add default:
#	my $domainfile = $cfg->val('Files', 'Domain') || "/etc/domain.yml";
	open my $ifh, '<', $domainfile
  		or die "Cannot open '$domainfile' for reading: $!";
# TODO: error check (file unreadable?)
	local $/ = '';
	my $contents = <$ifh>;
	close($ifh);

	my $c = shift;
  	$c->render(text => $contents);
};

get '/mgmtkey' => sub {
	my $mgmtfile = $cfg->val('Files', 'MgmtKey'); #TODO: add default
	open my $ifh, '<', $mgmtfile
  		or die "Cannot open '$mgmtfile' for reading: $!";
# TODO: error check (file unreadable?)
	local $/ = '';
	my $contents = <$ifh>;
	close($ifh);

	my $c = shift;
  	$c->render(text => $contents);
};

get '/epoptes-srv' => sub {
	my $c = shift;
	my $db = esmith::DB::db->open('hosts') || die("Could not open e-smith db (" . esmith::DB::db->error . ")\n");
	my @results = $db->get_all_by_prop(Role => 'docenti');
	if (@results) {
		$c->render(text => $results[0]->key);
	} else {
		$c->render(text => 'none');
	}
};

get '/ansible_host' => sub {
	my $c = shift;
	my $role = $c->param('role');
	if ( ! $role) {
		my $client = $c->get_client;
		if ($client) {
			$role = $client->prop('Role');
		} else {
			$role = 'unknown';
		}
	}
	my $vars = $c->role_vars($role) || {};
	$c->render(json => $vars );
};

get '/ansible_list' => sub {
	my $c = shift;
	my $role = $c->param('role');
	if ( ! $role) {
		my $client = $c->get_client;
		if ($client) {
			$role = $client->prop('Role');
		} else {
			$role = 'unknown';
		}
	}
	my $vars = $c->role_vars($role) || {};
	$c->render(json => {
		localhost => {
			hosts => [ 'localhost' ],
			vars => { ansible_connection => 'local' },
		},
		_meta => { hostvars => { localhost => $vars } }
	} );
};


get '/mac2hostname' => sub {
	my $c = shift;
	my $defaultrole = $cfg->val('NameSettings', 'Role') || 'client';
	my $defaultbase = $cfg->val('NameSettings', 'Base') || 'lab';
	my $mac = $c->param('mac');
	if (! $mac) {
		$c->render(text => 'Usage: GET /mac2hostname?mac=XX_XX_XX_XX_XX_XX[&base=YYY][&role=ZZZ]');
	}
	my $role = $c->param('role') || $defaultrole;
	my $base = $c->param('base') || $defaultbase;
	my $hostname = $c->new_hostname($mac, $base, $role);
	$c->render(text => $hostname);
};

get '/whatsmyhostname' => sub {
	my $c = shift;
	my $mac = $c->get_client_mac;
	my $role = $cfg->val('NameSettings', 'Role') || 'client';
	my $base = $cfg->val('NameSettings', 'Base') || 'lab';
	my $hostname = $c->new_hostname($mac, $base, $role);
	$c->render(text => $hostname);
};

helper 'new_hostname' => sub {
	my $c = shift;
	my $mac = shift;
	my $base = shift;
	my $role = shift;
	my $client;

	if ( ! $mac =~ /^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$/) {
		return "invalid mac address";
	}

	$client = $c->get_client($mac);
	if ($client) {
		return $client->key;
	}

	my $domainname = '';
    my $configdb = esmith::ConfigDB->open_ro;
	my $record = $configdb->get('DomainName');
    if ($record) {
        $domainname = $record->value;
    }
	my $digits = $cfg->val('NameSettings', 'Digits') || 2;
	my $formatstring = '%s-%0'.$digits.'d';
	my $hostname;
  my $db = esmith::DB::db->open('hosts') || die("Could not open e-smith db (" . esmith::DB::db->error . ")\n");
  	my $nr=0;
	while (1) {
		$nr++;
		$hostname = sprintf($formatstring, $base, $nr);
		if ($domainname ne '') {
			$hostname .= '.' . $domainname;
		}
		if (!$db->get($hostname)) {
			last;
		}
	}
	$client = $db->new_record($hostname, {
		'type' 			=> 'remote',
		'MacAddress'    => $mac,
		'Role'   		=> $role,
		'Description' 	=> '' });
	return $hostname;
};


#  def __route(self):
#    self.__app.get('/hosts', callback=self.hosts)
#    self.__app.get('/vaultpass', callback=self.vaultpass)

helper 'get_client' => sub {
  my $c = shift;
  my $mac = $c->get_client_mac;
  my $db = esmith::DB::db->open('hosts') || die("Could not open e-smith db (" . esmith::DB::db->error . ")\n");
  my @results = $db->get_all_by_prop(MacAddress => $mac);
  if (@results) {
	  return $results[0];
  } else {
	  return 0;
  }
};

helper 'get_client_mac' => sub {
  my $c = shift;
  my $remote_addr = $c->tx->remote_address;
  # $c->tx->original_remote_address
  my $p = Net::Ping->new();
  $p->ping($remote_addr, 1);
  # TODO: parametrizzare eth0 ??
  my $mac = Net::ARP::arp_lookup("eth0",$remote_addr);
  return $mac;
};

helper 'role_vars' => sub {
  my $c = shift;
  my $role = shift;
  my $db = esmith::DB::db->open('roles') || die("Could not open e-smith db (" . esmith::DB::db->error . ")\n");
  my @results = $db->get($role);
  if (@results) {
	  return {
		  role => $role,
		  delpkg => [ split "\n", $results[0]->prop('Delpkg') ],
		  addpkg => [ split "\n", $results[0]->prop('Addpkg') ],
	  };
  } else {
	  return 0;
  }
};

get '/hosts' => sub {
 	my $c = shift;
  	my $role = $c->param('role');
  	my $db = esmith::DB::db->open('hosts') || die("Could not open e-smith db (" . esmith::DB::db->error . ")\n");
  	my @results;
  	my @data;
  	if ( $role ) {
		@results = $db->get_all_by_prop(Role => $role);
  	} else {
		@results = $db->get_all;
  	}

  	foreach my $r (@results) {
	  	push @data, {
		  	mac => $r->prop('MacAddress'),
          	hostname => $r->key,
          	role => $r->prop('Role')
	  	};
  	}

  	$c->render(json => @data );
};





app->start;
#app->start('daemon', '-l', 'http://*:8888');