#  Copyright (C) 2010  Stanislav Sinyagin
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software

# Command-line interface wrapper


package Gerty::Access::CLI;

use strict;
use warnings;
use Expect qw(exp_continue);
use Date::Format;


my %has =
    ('expect' => 1);


my %known_access_methods =
    ('ssh' => 1,
     'telnet' => 1);


     
sub new
{
    my $self = {};
    my $class = shift;    
    $self->{'options'} = shift;
    bless $self, $class;

    foreach my $opt ('job', 'device')
    {
        if( not defined( $self->{'options'}->{$opt} ) )
        {
            $Gerty::log->critical('Gerty::Access::CLI::new: Missing ' . $opt);
            return undef;
        }
    }

    my $sysname = $self->{'options'}->{'device'}->{'SYSNAME'};

    # Fetch mandatory attributes

    foreach my $attr ('cli.access-method')
    {
        my $val = $self->device_attr($attr);
        if( not defined($val) )
        {
            $Gerty::log->error
                ('Missing mandatory attribute "' . $attr . '" for device: ' .
                 $sysname);
            return undef;
        }
        else
        {
            $self->{'attr'}{$attr} = $val;
        }       
    }

    if( not $known_access_methods{ $self->{'attr'}{'cli.access-method'} } )
    {
        $Gerty::log->error
            ('Unsupported cli.access-method value: "' .
             $self->{'attr'}{'cli.access-method'} . '" for device: ' .
             $sysname);
        return undef;
    }
    
    
    # Fetch mandatory credentials
    
    foreach my $attr ('cli.auth-username', 'cli.auth-password')
    {
        my $val = $self->device_credentials_attr($attr);
        if( not defined($val) )
        {
            $Gerty::log->error
                ('Missing mandatory credentials attribute "' .
                 $attr . '" for device: ' .
                 $sysname);
            return undef;
        }
        else
        {
            $self->{'attr'}{$attr} = $val;
        }       
    }

    # Fetch other attributes

    foreach my $attr
        ('cli.ssh-port', 'cli.telnet-port', 'cli.log-dir', 
         'cli.logfile-timeformat', 'cli.timeout', 'cli.initial-prompt')
    {
        my $val = $self->device_attr($attr);
        if( not defined($val) )           
        {
            $Gerty::log->error
                ('Missing mandatory attribute "' .
                 $attr . '" for device: ' . $sysname);
            return undef;
        }
        $self->{'attr'}{$attr} = $val;        
    }

    # Fetch optional attributes
    
    foreach my $attr ('cli.cr-before-login')
    {
        my $val = $self->device_attr($attr);
        if( defined($val) )
        {
            $self->{'attr'}{$attr} = $val;        
        }
    }

    return $self;
}


sub has
{
    my $self = shift;
    my $what = shift;
    return $has{$what};
}
    


sub device_attr
{
    my $self = shift;
    my $attr = shift;

    return $self->{'options'}->{'job'}->device_attr
        ( $self->{'options'}->{'device'}, $attr );
}


sub device_credentials_attr
{
    my $self = shift;
    my $attr = shift;

    return $self->{'options'}->{'job'}->device_credentials_attr
        ( $self->{'options'}->{'device'}, $attr );
}



# Returns an Expect object after authentication
sub connect
{
    my $self = shift;

    my $exp = $self->_open_expect();
    
    my $sysname = $self->{'options'}->{'device'}->{'SYSNAME'};
    my $method = $self->{'attr'}{'cli.access-method'};            
    my $ipaddr = $self->{'options'}->{'device'}{'ADDRESS'};
    
    $Gerty::log->debug('Connecting to ' . $ipaddr . ' with ' . $method);

    if( $method eq 'ssh' )
    {
        my @exec_args =
            ($Gerty::external_executables{'ssh'},
             '-o', 'NumberOfPasswordPrompts=1',
             '-p', $self->{'attr'}{'cli.ssh-port'},
             '-l', $self->{'attr'}{'cli.auth-username'},
             $ipaddr);

        if( not $exp->spawn(@exec_args) )
        {
            $Gerty::log->error('Failed spawning command "' .
                               join(' ', @exec_args) . '": ' . $!);
            return undef;
        }

        if( not $self->_login_ssh($exp) )
        {
            return undef;
        }        
    }
    elsif( $method eq 'telnet' )
    {
        my @exec_args =
            ($Gerty::external_executables{'telnet'},
             $ipaddr,
             $self->{'attr'}{'cli.telnet-port'});
        
        if( not $exp->spawn(@exec_args) )
        {
            $Gerty::log->error('Failed spawning command "' .
                               join(' ', @exec_args) . '": ' . $!);
            return undef;
        }

        if( not $self->_login_telnet($exp) )
        {
            return undef;
        }        
    }
    
    $Gerty::log->debug('Logged in at ' . $ipaddr);
    $self->{'expect'} = $exp;
    return $exp;
}


sub close
{
    my $self = shift;

    if( defined($self->{'expect'}) )
    {
        $self->{'expect'}->hard_close();
        undef $self->{'expect'};
    }
}


sub expect
{
    my $self = shift;

    return $self->{'expect'};
}



# Creates an Expect object and initializes logging
sub _open_expect
{
    my $self = shift;

    my $sysname = $self->{'options'}->{'device'}->{'SYSNAME'};

    my $exp = new Expect();
    if( not $Gerty::expect_debug )
    {
        $exp->log_stdout(0);
    }
    
    my $logdir = $self->{'attr'}{'cli.log-dir'};
    if( length($logdir) > 0 )
    {
        if( not -d $logdir )
        {
            $Gerty::log->warning
                ('The directory ' . $logdir . ' is specified as cli.log-dir ' .
                 ' for ' . $sysname . ' does not exist ');
        }
        else
        {
            $exp->log_file
                (sprintf('%s/%s.%s.log',
                         $logdir, $sysname,
                         time2str($self->{'attr'}{'cli.logfile-timeformat'},
                                  time())));
        }
    }
    else
    {
        $Gerty::log->info
            ('cli.log-dir is not specified for ' . $sysname .
             ', CLI logging is disabled');
    }

    return $exp;
}

    
# login sequence after launching the SSH executable
sub _login_ssh
{
    my $self = shift;
    my $exp = shift;

    my $sysname = $self->{'options'}->{'device'}->{'SYSNAME'};

    # Handle unknown host and password
    my $password = $self->{'attr'}{'cli.auth-password'};
    my $timeout =  $self->{'attr'}{'cli.timeout'};
    my $prompt = $self->{'attr'}{'cli.initial-prompt'};
    my $failure;
    
    if( not defined
        $exp->expect
        ( $timeout,
          ['-re', qr/yes\/no.*/i, sub {
              $exp->send("yes\r"); exp_continue;}],
          ['-re', qr/password:/i, sub {
              $exp->send($password . "\r"); exp_continue;}],
          ['-re', $prompt],
          ['timeout', sub {$failure = 'Connection timeout'}],
          ['-re', qr/closed/i, sub {$failure = 'Connection closed'}],
          ['eof', sub {$failure = 'Connection closed'}]) )
    {
        $Gerty::log->error
            ('Could not match the output for ' . $sysname . ': ' . 
             $exp->before());            
        $exp->hard_close();
        return undef;
    }
        
    if( defined($failure))
    {
        $Gerty::log->error
            ('Failed logging into ' . $sysname . ': ' . $failure);
        $exp->hard_close();
        return undef;
    }

    return 1;    
}



# login sequence after launching the Telnet executable
sub _login_telnet
{ 
    my $self = shift;
    my $exp = shift;

    my $sysname = $self->{'options'}->{'device'}->{'SYSNAME'};

    # Log into the remote system
    my $login = $self->{'attr'}{'cli.auth-username'};
    my $password = $self->{'attr'}{'cli.auth-password'};
    my $timeout =  $self->{'attr'}{'cli.timeout'};
    my $prompt = $self->{'attr'}{'cli.initial-prompt'};
    my $failure;
    
    if( $self->{'attr'}{'cli.cr-before-login'} )
    {
        $exp->send("\r");
    }
        
    if( not defined
        $exp->expect
        ( $timeout,
          ['-re', qr/Escape\s+character\s+is\S+/i, sub {
              exp_continue; }],
          ['-re', qr/login:/i, sub {
              $exp->send($login . "\r"); exp_continue;}],
          ['-re', qr/name:/i, sub {
              $exp->send($login . "\r"); exp_continue;}],
          ['-re', qr/password:/i, sub {
              $exp->send($password . "\r"); exp_continue;}],
          ['-re', qr/incorrect/i, sub {$failure = 'Access denied'}],
          ['-re', qr/denied/i, sub {$failure = 'Access denied'}],
          ['-re', qr/fail/i, sub {$failure = 'Access denied'}],
          ['-re', qr/refused/i, sub {$failure = 'Connection refused'}],
          ['timeout', sub {$failure = 'Connection timeout'}],
          ['eof', sub {$failure = 'Connection closed'}],
          ['-re', $prompt] ) )
    {
        $Gerty::log->error
            ('Could not match the output for ' . $sysname . ': ' . 
             $exp->before());            
        $exp->hard_close();
        return undef;
    }
    
    if( defined($failure) )
    {
        $Gerty::log->error
            ('Failed connecting to ' . $sysname . ': ' . $failure);
        $exp->hard_close();
        return undef;
    }

    return 1;
}


             
1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End: