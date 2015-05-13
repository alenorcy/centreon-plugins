################################################################################
# Copyright 2005-2014 MERETHIS
# Centreon is developped by : Julien Mathis and Romain Le Merlus under
# GPL Licence 2.0.
# 
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation ; either version 2 of the License.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A 
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
# 
# Linking this program statically or dynamically with other modules is making a 
# combined work based on this program. Thus, the terms and conditions of the GNU 
# General Public License cover the whole combination.
# 
# As a special exception, the copyright holders of this program give MERETHIS 
# permission to link this program with independent modules to produce an executable, 
# regardless of the license terms of these independent modules, and to copy and 
# distribute the resulting executable under terms of MERETHIS choice, provided that 
# MERETHIS also meet, for each linked independent module, the terms  and conditions 
# of the license of that module. An independent module is a module which is not 
# derived from this program. If you modify this program, you may extend this 
# exception to your version of the program, but you are not obliged to do so. If you
# do not wish to do so, delete this exception statement from your version.
# 
# For more information : contact@centreon.com
# Authors : Quentin Garnier <qgarnier@merethis.com>
#
####################################################################################

package apps::activedirectory::local::mode::dcdiag;

use base qw(centreon::plugins::mode);

use strict;
use warnings;
use centreon::plugins::misc;
use File::Basename;
use XML::LibXML;
use Win32;

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;
    
    $self->{version} = '1.0';
    $options{options}->add_options(arguments =>
                                { 
                                  "config:s"         => { name => 'config', },
                                  "language:s"       => { name => 'language', default => 'en' },
                                  "dfsr"             => { name => 'dfsr', },
                                  "noeventlog"       => { name => 'noeventlog', },
                                  "timeout:s"         => { name => 'timeout', default => 30 },
                                });
    $self->{os_is2003} = 0;
    $self->{os_is2008} = 0;
    $self->{os_is2012} = 0;
    
    $self->{msg} = {global => undef, ok => undef, warning => undef, critical => undef};
    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::init(%options);
    if (defined($self->{option_results}->{config})) {
        $self->{config_file} = $self->{option_results}->{config};
    } else {
        $self->{output}->add_option_msg(short_msg => "Need to specify config file option.");
        $self->{output}->option_exit();;
    }
}

sub check_version {
    my ($self, %options) = @_;

    our ($ver_string, $ver_major, $ver_minor, $ver_build, $ver_id) = Win32::GetOSVersion();    
    #"Operating system is " . "$ver_string - ($ver_id.$ver_major.$ver_minor.$ver_build)\n";
    
    # 5.1, 5.2 => XP/2003
    # 6.0, 6.1 => Vista/7/2008
    # 6.2, 6.3 => 2012
    if ($ver_major == 5 && ($ver_minor == 1 || $ver_minor == 2)) {
        $self->{os_is2003} = 1;
    } elsif ($ver_major == 6 && ($ver_minor == 0 || $ver_minor == 1)) {
        $self->{os_is2008} = 1;
    } elsif ($ver_major == 6 && ($ver_minor == 2 || $ver_minor == 3)) {
        $self->{os_is2012} = 1;
    } else {
        $self->{output}->output_add(severity => 'UNKNOWN',
                                    short_msg => 'OS version ' . $ver_major . '.' . $ver_minor . ' not managed.');
        return 1;
    }
    return 0;
}

sub load_xml {
    my ($self, %options) = @_;

    # Load XML File
    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file($self->{config_file});
    my $nodes = $doc->getElementsByTagName('dcdiag');
    if ($nodes->size() == 0) {
        $self->{output}->output_add(severity => 'UNKNOWN',
                                    short_msg => 'Cannot find a <dcdiag> node in XML Config file');
        return 1;
    }
    
    my $language_found = 0;
    foreach my $node ($nodes->get_nodelist()) {
        if ($node->getAttribute('language') eq $self->{option_results}->{language}) {
            $language_found = 1;
            my $messages_node = $node->getElementsByTagName('messages');
            foreach my $node2 ($messages_node->get_nodelist()) {
                foreach my $element_msg ($node2->getChildrenByTagName('*')) {
                    $self->{msg}->{$element_msg->nodeName} = $element_msg->textContent if (exists($self->{msg}->{$element_msg->nodeName}));
                }
            }
            last;
        }
    }
    
    if ($language_found == 0) {
        $self->{output}->output_add(severity => 'UNKNOWN',
                                    short_msg => "Cannot found language '" . $self->{option_results}->{language} . "' in XML Config file");
        return 1;
    }
    
    foreach my $label (keys %{$self->{msg}}) {
        if (!defined($self->{msg}->{$label})) {
            $self->{output}->output_add(severity => 'UNKNOWN',
                                        short_msg => "Message '" . $label . "' for language '" . $self->{option_results}->{language} . "' not defined in XML Config file");
            return 1;
        }
    }
        
    return 0;
}

sub dcdiag {
    my ($self, %options) = @_;

    my $dcdiag_cmd = 'dcdiag /test:services /test:replications /test:advertising /test:fsmocheck /test:ridmanager /test:machineaccount';
    $dcdiag_cmd .= ' /test:frssysvol' if ($self->{os_is2003} == 1);
    $dcdiag_cmd .= ' /test:sysvolcheck' if ($self->{os_is2008} == 1 || $self->{os_is2012} == 1);
    
    if (!defined($self->{option_results}->{noeventlog})) {
        $dcdiag_cmd .= ' /test:frsevent /test:kccevent' if ($self->{os_is2003} == 1);
        $dcdiag_cmd .= ' /test:frsevent /test:kccevent' if (($self->{os_is2008} == 1 || $self->{os_is2012} == 1) && !defined($self->{option_results}->{dfsr}));
        $dcdiag_cmd .= ' /test:dfsrevent /test:kccevent' if (($self->{os_is2008} == 1 || $self->{os_is2012} == 1) && defined($self->{option_results}->{dfsr}));
    }
    
    my ($stdout) = centreon::plugins::misc::windows_execute(output => $self->{output},
                                                            timeout => $self->{option_results}->{timeout},
                                                            command => $dcdiag_cmd,
                                                            command_path => undef,
                                                            command_options => undef);
    
    my $match = 0;
    while ($stdout =~ /$self->{msg}->{global}/imsg) {
        my ($test_name, $pattern) = ($1, lc($2));
		    
        if ($pattern =~ /$self->{msg}->{ok}/i) {
            $match = 1;
            $self->{output}->output_add(severity => 'OK',
                                        short_msg => $test_name);
        } elsif ($pattern =~ /$self->{msg}->{critical}/i) {
            $match = 1;
            $self->{output}->output_add(severity => 'CRITICAL',
                                        short_msg => 'test ' . $test_name);
        } elsif ($pattern =~ /$self->{msg}->{warning}/i) {
            $match = 1;
            $self->{output}->output_add(severity => 'WARNING',
                                        short_msg => 'test ' . $test_name);
        }
    }
    
    if ($match == 0) {
        $self->{output}->output_add(severity => 'UNKNOWN',
                                    short_msg => 'Cannot match output test (maybe you need to set the good language)');
        return 1;
    }
    
    return 0;
}

sub run {
    my ($self, %options) = @_;

    if ($self->load_xml() == 0 && $self->check_version() == 0) {
        $self->dcdiag();
    }
   
    $self->{output}->display();
    $self->{output}->exit();
}

1;

__END__

=head1 MODE

Check Windows Active Directory Health (use 'dcdiag' command).

=over 8

=item B<--config>

command can be localized by using a configuration file.
This parameter can be used to specify an alternative location for the configuration file

=item B<--language>

Set the language used in config file (default: 'en').

=item B<--dfsr>

Specifies that SysVol replication uses DFS instead of FRS (Windows 2008 or later)

=item B<--noeventlog>

Don't run the dc tests kccevent, frsevent and dfsrevent

=item B<--timeout>

Set timeout time for command execution (Default: 30 sec)

=back

=cut