use v6;
unit class HTTP::Server::Tiny;

use Raw::Socket::INET;
use HTTP::Request::Parser;
use NativeCall;
use File::Temp;

my class IO::Scalar::Empty {
    method eof() { True }
    method read(Int(Cool:D) $bytes) {
        my $buf := buf8.new;
        return $buf;
    }
    method close() {
    }
}

has $.port = 80;
has $.host = '127.0.0.1';

has $!sock;

has %pids;

has Bool $shown-banner;

sub info($message) {
    say "[INFO] [{$*THREAD.id}] $message";
}

constant DEBUGGING = %*ENV<DEBUGGING>.Bool;

macro debug($message) {
    if DEBUGGING {
        quasi {
            say "[DEBUG] [{$*THREAD.id}] " ~ {{{$message}}};
        }
    } else {
        quasi { }
    }
}

method new($host, $port) {
    self.bless(host => $host, port => $port)!initialize;
}

method !initialize() {
    $!sock = IO::Socket::Async.listen($.host, $.port);
    self;
}

method run(Sub $app) {
    self!show-banner;

    loop {
        my $csock = $!sock.accept();
        LEAVE {
            CATCH { default { say "[ERROR] $_" } }
            say "closing socket";
            $csock.close
        }

        self.handler($csock, $app);

        CATCH { default { say "[ERROR] $_" } }
    }
    die "should not reach here";
}

method !show-banner() {
    # TODO: I want to use IO::Socket::Async#port method to use port 0.
    unless $!shown-banner {
        say "http server is ready: http://$.host:$.port/";
        $!shown-banner = True;
    }
}

sub error($err) {
    say "[{$*THREAD.id}] [ERROR] $err {$err.backtrace.full}";
}

method run-async(Int $workers, Sub $app) {
    info("run async: workers:$workers");

    my sub run-app($env) {
        CATCH {
            error($_);
            return [500, [], ['Internal Server Error!']];
        };
        return $app.($env);
    };

    self!show-banner;

    react {
        whenever IO::Socket::Async.listen($.host, $.port) -> $conn {
            debug("new request");
            my Buf $buf .= new;
            my $header-parsed = False;

            my $tmpfname = $*TMPDIR.child("p6-httpd" ~ nonce());
            # LEAVE { try unlink $tmpfname }
            my $tmpfh;

            my Hash $env;
            my $got-content-len = 0;

            $conn.bytes-supply.tap(sub ($got) {
                $buf ~= $got;
                debug("got");

                unless $header-parsed {
                    my ($done, $got-env, $header_len) = parse-http-request($buf);
                    debug("http parsing status: $done");
                    unless $done {
                        return;
                    }
                    if $buf.elems > $header_len {
                        $buf = $buf.subbuf($header_len);
                    }
                    $env = $got-env;
                    $header-parsed = True;
                }

                if $buf.elems > 0 {
                    $tmpfh //= open($tmpfname, :rw);
                    $tmpfh.write($buf); # XXX blocking
                    $buf = Buf.new;
                }

                if $env<CONTENT_LENGTH>.defined {
                    my $cl = $env<CONTENT_LENGTH>.Int;
                    unless $cl == $got-content-len {
                        return;
                    }
                    $tmpfh.seek(0,0); # rewind
                    $env<psgi.input> = $tmpfh;
                } else {
                    # TODO: chunked request support
                    $env<psgi.input> = IO::Scalar::Empty.new;
                }

                $tmpfh.close;

                CATCH { default { error($_) } }

                my $resp = run-app($env);

                self!send-response($conn, $resp);
                $conn.close; # TODO: keep-alive

                try $env<psgi.input>.close;
                try unlink $tmpfname;
            }, done => sub {
                debug "DONE";
                try unlink $tmpfname;
                try $tmpfh.close if $tmpfh;
            }, quit => sub {
                debug 'quit';
            }, closing => sub {
                debug 'closing';
            });
        }
    }
}

my sub nonce () { return (".{$*PID}." ~ flat('a'..'z', 'A'..'Z', 0..9, '_').roll(10).join) }

method !send-response($csock, Array $res) {
    debug "sending response";
    my $resp_string = "HTTP/1.0 $res[0] perl6\r\n";
    for @($res[1]) {
        if .key ~~ /<[\r\n]>/ {
            die "header split";
        }
        $resp_string ~= "{.key}: {.value}\r\n";
    }
    $resp_string ~= "\r\n";
    my $resp = $resp_string.encode('ascii');
    $csock.write($resp);
    if $res[2].isa(Array) {
        for @($res[2]) -> $elem {
            if $elem.does(Blob) {
                $csock.write($elem);
            } else {
                die "response must be Array[Blob]. But {$elem.perl}";
            }
        }
    } elsif $res[2].isa(IO) {
        # TODO: support IO response
        die "IO is not supported yet";
    } else {
        die "3rd element of response object must be instance of Array or IO";
    }
}

=begin pod

=head1 NAME

HTTP::Server::Tiny - blah blah blah

=head1 SYNOPSIS

  use HTTP::Server::Tiny;

=head1 DESCRIPTION

HTTP::Server::Tiny is ...

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Tokuhiro Matsuno <tokuhirom@gmail.com>

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
