use strict;
use warnings;

use feature qw(state);

use if $] < 5.026, 'Function::Parameters', { sub => 'function' };
use if $] >= 5.026, experimental => qw(signatures);
#use Function::Parameters { sub => 'function' };

use Object::Pad;
use App::cpanminus::fatscript;

class App::cpanminus::Formatted 0.01 {
    field $app :reader;
    field $argv :param = undef;
    
    ADJUSTPARAMS ($params) {
        $app = App::cpanminus::Formatted::script->new(%$params);
    }

    method doit {
        $app->parse_options($argv ? @$argv : @ARGV);
        $app->doit;
    }

    method run { $self->doit; }
}

class App::cpanminus::Formatted::script 0.01 :isa(App::cpanminus::script) {
    use Class::Method::Modifiers;

    field %hooks;
    
    field @work;
    field %work_by_module;
    
    field $indent_string :param = '  ';
    
    field $version_format =
      "cpanmf (App::cpanminus::Formatted) version %s\n";

    ADJUSTPARAMS ($params) {
        %hooks = %{ delete $params->{hooks} };
    }


    # Notes: The sub { method {} } wrappers below are for working-around
    #        the 'around' modifier not having $self as the first argument.
    #        The method {} is needed to be able to access fields slots.
    #        Also, $obj was chosen instead of $self in the arg list to
    #        differentiate from the $self exposed inside of a method block.


    # Observe each module installation.
    around install_module => sub ($code, $obj, $module, $depth, $version) {
        method {
            push @work, $work_by_module{$module} = {
                index  => $self->{installed_dists},
                module => $module,
                depth  => $depth
            };

            #$module .= 'FOO' if $module eq 'AnyEvent::Future';

            $hooks{before_install}->($self) if $hooks{before_install};
            $work[-1]->{status} = $self->$code($module, $depth, $version);
            $hooks{after_install}->($self) if $hooks{after_install};

            return (pop @work)->{status};
        }->($obj);
    };

    # Gather dependency list for the current module.
    before install_deps => method ($dir, $depth, @deps) {
        $work[-1]->{deps} = \@deps;
        $hooks{before_install_deps}->($self) if $hooks{before_install_deps};
    };
    after install_deps => method ($dir, $depth, @deps) {
        $hooks{after_install_deps}->($self) if $hooks{after_install_deps};
    };

    # Gather dist and release information.
    around cpan_module => sub ($code, $obj, $module, $dist_file, $version) {
        method {
            my $dist = $self->$code($module, $dist_file, $version);

            my $w = $work_by_module{$module};
            $w->{dist}      = $dist;
            $w->{dist_file} = $dist_file;
            $w->{version}   = $version;

            return $dist;
        }->($obj);
    };


    # General output, what typically prints to the terminal.
    around _diag => sub ($code, $obj, $msg, @rest) {
        state %status;

        method {
            if ( $hooks{before_output} ) {
                my $depth = $self->work_prop('depth') // 0;

                $status{last_msg}   //= '';
                $status{last_depth} //= 0;
                $status{is_bol}     //= 1;
                $status{is_bob}       = 0;
                $status{msg}          = $msg;
                $status{depth}        = $depth;

                # Is this the start of a new work block?
                if ( $msg =~ /^\!/ && $status{last_msg} !~ /^\!/ ) {
                    $status{is_bob} = 1;
                }
                elsif ( $depth != $status{last_depth} ) {
                    $status{is_bob} = 1;
                }
                elsif ( $msg =~ /^\Q--> Working on/ ) {
                    if ( $depth > 0 || $self->{installed_dists} > 0 ) {
                        $status{is_bob} = 1;
                    }
                }

                # Has the installation phase finished?
                $status{at_end} = $msg =~ /^\d+ distributions installed/;

                # Invoke callback.
                $hooks{before_output}->( $self, \$msg, %status );

                # Will the next $msg be the beginning of a new line?
                $status{is_bol}     = $msg =~ /\n$/;

                $status{last_depth} = $depth;
                $status{last_msg}   = $status{msg}; # Unmodified message.
            }

            $self->$code($msg, @rest);
        }->($obj);
    };

    around show_version => sub ($code, $obj, @args) {
        method {
            my ($buff, $ret) = $self->call_and_capture_stdout($code, @args);

            my $line = $self->version_line;

            print $buff =~ s/\n\K/$line/r;

            return $ret;
        }->($obj);
    };


    method version_line {
        return sprintf $version_format, __CLASS__->VERSION;
    }

    method work($i = -1) { return $work[$i]; }

    method work_prop($key, $i = -1) {
        return @work ? $work[$i]->{$key} : undef;
    }

    method indent($s, $is = $indent_string, $i = -1) {
        my $prefix = @work ? $is x $work[$i]->{depth} : '';
        my $indented = $prefix. (ref $s ? $$s : $s);

        $$s = $indented if ref $s;

        return unless defined wantarray; # Return empty in void context.
        return $indented;
    }

    method installed_dists { return $self->{installed_dists}; }

    method call_and_capture_stdout($meth, @args) {
        local *STDOUT;
        open STDOUT, ">", \my $buff;
        my $ret = $self->$meth(@args);
        return $buff, $ret;
    }
}

1;
