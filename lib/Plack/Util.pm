package Plack::Util;
use strict;
use Carp ();
use Scalar::Util;
use IO::Handle;
use Try::Tiny;

sub TRUE()  { 1==1 }
sub FALSE() { !TRUE }

sub load_class {
    my($class, $prefix) = @_;

    if ($prefix) {
        unless ($class =~ s/^\+// || $class =~ /^$prefix/) {
            $class = "$prefix\::$class";
        }
    }

    my $file = $class;
    $file =~ s!::!/!g;
    require "$file.pm"; ## no critic

    return $class;
}

sub is_real_fh ($) {
    my $fh = shift;

    my $reftype = Scalar::Util::reftype($fh);
    if (   $reftype eq 'IO'
        or $reftype eq 'GLOB' && *{$fh}{IO}
    ) {
        # if it's a blessed glob make sure to not break encapsulation with
        # fileno($fh) (e.g. if you are filtering output then file descriptor
        # based operations might no longer be valid).
        # then ensure that the fileno *opcode* agrees too, that there is a
        # valid IO object inside $fh either directly or indirectly and that it
        # corresponds to a real file descriptor.
        my $m_fileno = $fh->fileno;
        return FALSE unless defined $m_fileno;
        return FALSE unless $m_fileno >= 0;

        my $f_fileno = fileno($fh);
        return FALSE unless defined $f_fileno;
        return FALSE unless $f_fileno >= 0;
        return TRUE;
    } else {
        # anything else, including GLOBS without IO (even if they are blessed)
        # and non GLOB objects that look like filehandle objects cannot have a
        # valid file descriptor in fileno($fh) context so may break.
        return FALSE;
    }
}

sub set_io_path {
    my($fh, $path) = @_;
    bless $fh, 'Plack::Util::IOWithPath';
    $fh->path($path);
}

sub content_length {
    my $body = shift;

    return unless defined $body;

    if (ref $body eq 'ARRAY') {
        my $cl = 0;
        for my $chunk (@$body) {
            $cl += length $chunk;
        }
        return $cl;
    } elsif ( is_real_fh($body) ) {
        return (-s $body) - tell($body);
    }

    return;
}

sub foreach {
    my($body, $cb) = @_;

    if (ref $body eq 'ARRAY') {
        for my $line (@$body) {
            $cb->($line) if length $line;
        }
    } else {
        local $/ = \4096 unless ref $/;
        while (defined(my $line = $body->getline)) {
            $cb->($line) if length $line;
        }
        $body->close;
    }
}

sub class_to_file {
    my $class = shift;
    $class =~ s!::!/!g;
    $class . ".pm";
}

sub load_psgi {
    my $stuff = shift;

    my $file = $stuff =~ /^[a-zA-Z0-9\_\:]+$/ ? class_to_file($stuff) : $stuff;
    my $app = require $file;
    return $app->to_app if $app and Scalar::Util::blessed($app) and $app->can('to_app');
    return $app if $app and (ref $app eq 'CODE' or overload::Method($app, '&{}'));

    if (my $e = $@ || $!) {
        die "Can't load $file: $e";
    } else {
        Carp::croak("$file doesn't return PSGI app handler: " . ($app || undef));
    }
}

sub run_app($$) {
    my($app, $env) = @_;

    return try {
        $app->($env);
    } catch {
        my $body = "Internal Server Error";
        $env->{'psgi.errors'}->print($_);
        return [ 500, [ 'Content-Type' => 'text/plain', 'Content-Length' => length($body) ], [ $body ] ];
    }
}

sub headers {
    my $headers = shift;
    inline_object(
        iter   => sub { header_iter($headers, @_) },
        get    => sub { header_get($headers, @_) },
        set    => sub { header_set($headers, @_) },
        push   => sub { header_push($headers, @_) },
        exists => sub { header_exists($headers, @_) },
        remove => sub { header_remove($headers, @_) },
        headers => sub { $headers },
    );
}

sub header_iter {
    my($headers, $code) = @_;

    my @headers = @$headers; # copy
    while (my($key, $val) = splice @headers, 0, 2) {
        $code->($key, $val);
    }
}

sub header_get {
    my($headers, $key) = (shift, lc shift);

    my @val;
    header_iter $headers, sub {
        push @val, $_[1] if lc $_[0] eq $key;
    };

    return wantarray ? @val : $val[0];
}

sub header_set {
    my($headers, $key, $val) = @_;

    my($set, @new_headers);
    header_iter $headers, sub {
        if (lc $key eq lc $_[0]) {
            return if $set;
            $_[1] = $val;
            $set++;
        }
        push @new_headers, $_[0], $_[1];
    };

    push @new_headers, $key, $val unless $set;
    @$headers = @new_headers;
}

sub header_push {
    my($headers, $key, $val) = @_;
    push @$headers, $key, $val;
}

sub header_exists {
    my($headers, $key) = (shift, lc shift);

    my $exists;
    header_iter $headers, sub {
        $exists = 1 if lc $_[0] eq $key;
    };

    return $exists;
}

sub header_remove {
    my($headers, $key) = (shift, lc shift);

    my @new_headers;
    header_iter $headers, sub {
        push @new_headers, $_[0], $_[1]
            unless lc $_[0] eq $key;
    };

    @$headers = @new_headers;
}

sub status_with_no_entity_body {
    my $status = shift;
    return $status < 200 || $status == 204 || $status == 304;
}

sub encode_html {
    my $str = shift;
    $str =~ s/&/&amp;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/'/&#39;/g;
    return $str;
}

sub inline_object {
    my %args = @_;
    bless {%args}, 'Plack::Util::Prototype';
}

package Plack::Util::Prototype;

our $AUTOLOAD;
sub can {
    exists $_[0]->{$_[1]};
}

sub AUTOLOAD {
    my ($self, @args) = @_;
    my $attr = $AUTOLOAD;
    $attr =~ s/.*://;
    if (ref($self->{$attr}) eq 'CODE') {
        $self->{$attr}->(@args);
    } else {
        Carp::croak(qq/Can't locate object method "$attr" via package "Plack::Util::Prototype"/);
    }
}

sub DESTROY { }

package Plack::Util::IOWithPath;
use parent qw(IO::Handle);

sub path {
    my $self = shift;
    if (@_) {
        ${*$self}{+__PACKAGE__} = shift;
    }
    ${*$self}{+__PACKAGE__};
}

package Plack::Util;

1;

__END__

=head1 NAME

Plack::Util - Utility subroutines for Plack server and framework developers

=head1 FUNCTIONS

=over 4

=item TRUE, FALSE

  my $true  = Plack::Util::TRUE;
  my $false = Plack::Util::FALSE;

Utility constants to include when you specify boolean variables in C<$env> hash (e.g. C<psgi.multithread>).

=item load_class

  my $class = Plack::Util::load_class($class [, $prefix ]);

Constructs a class name and C<require> the class. Throws an exception
if the .pm file for the class is not found, just with the built-in
C<require>.

If C<$prefix> is set, the class name is prepended to the C<$class>
unless C<$class> begins with C<+> sign, which means the class name is
already fully qualified.

  my $class = Plack::Util::load_class("Foo");                   # Foo
  my $class = Plack::Util::load_class("Baz", "Foo::Bar");       # Foo::Bar::Baz
  my $class = Plack::Util::load_class("+XYZ::ZZZ", "Foo::Bar"); # XYZ::ZZZ

=item is_real_fh

  if ( Plack::Util::is_real_fh($fh) ) { }

returns true if a given C<$fh> is a real file handle that has a file
descriptor. It returns false if C<$fh> is PerlIO handle that is not
really related to the underlying file etc.

=item content_length

  my $cl = Plack::Util::content_length($body);

Returns the length of content from body if it can be calculated. If
C<$body> is an array ref it's a sum of length of each chunk, if
C<$body> is a real filehandle it's a remaining size of the filehandle,
otherwise returns undef.

=item set_io_path

  Plack::Util::set_io_path($fh, "/path/to/foobar.txt");

Sets the (absolute) file path to C<$fh> filehandle object, so you can
call C<< $fh->path >> on it. As a side effect C<$fh> is blessed to an
internal package but it can still be treated as a normal file
handle.

This module doesn't normalize or absolutize the given path, and is
intended to be used from Server or Middleware implementations. See
also L<IO::File::WithPath>.

=item foreach

  Plack::Util::foreach($body, $cb);

Iterate through I<$body> which is an array reference or
IO::Handle-like object and pass each line (which is NOT really
guaranteed to be a I<line>) to the callback function.

It internally sets the buffer length C<$/> to 4096 in case it reads
the binary file, unless otherwise set in the caller's code.

=item load_psgi

  my $app = Plack::Util::load_psgi $psgi_file_or_class;

Load C<app.psgi> file or a class name (like C<MyApp::PSGI>) and
require the file to get PSGI application handler. If the file can't be
loaded (e.g. file doesn't exist or has a perl syntax error), it will
throw an exception.

B<Security>: If you give this function a class name or module name
that is loadable from your system, it will load the module. This could
lead to a security hole:

  my $psgi = ...; # user-input: consider "Moose.pm"
  $app = Plack::Util::load_psgi($psgi); # this does 'require "Moose.pm"'!

Generally speaking, passing an external input to this function is
considered very insecure. But if you really want to do that, be sure
to validate the argument passed to this function. Also, if you do not
want to accept an arbitrary class name but only load from a file path,
make sure that the argument C<$psgi_file_or_class> begins with C</> so
that Perl's built-in require function won't search the include path.

=item run_app

  my $res = Plack::Util::run_app $app, $env;

Runs the I<$app> by wrapping errors with I<eval> and if an error is
found, logs it to C<< $env->{'psgi.errors'} >> and returns the
template 500 Error response.

=item header_get, header_exists, header_set, header_push, header_remove

  my $hdrs = [ 'Content-Type' => 'text/plain' ];

  my $v = Plack::Util::header_get($hdrs, $key); # First found only
  my @v = Plack::Util::header_get($hdrs, $key);
  my $bool = Plack::Util::header_exists($hdrs, $key);
  Plack::Util::header_set($hdrs, $key, $val);   # overwrites existent header
  Plack::Util::header_push($hdrs, $key, $val);
  Plack::Util::header_remove($hdrs, $key);

Utility functions to manipulate PSGI response headers array
reference. The methods that read existent header value handles header
name as case insensitive.

  my $hdrs = [ 'Content-Type' => 'text/plain' ];
  my $v = Plack::Util::header_get('content-type'); # 'text/plain'

=item headers

  my $headers = [ 'Content-Type' => 'text/plain' ];

  my $h = Plack::Util::headers($headers);
  $h->get($key);
  if ($h->exists($key)) { ... }
  $h->set($key => $val);
  $h->push($key => $val);
  $h->remove($key);
  $h->headers; # same reference as $headers

Given a header array reference, returns a convenient object that has
an instance methods to access C<header_*> functions with an OO
interface. The object holds a reference to the original given
C<$headers> argument and updates the reference accordingly when called
write methods like C<set>, C<push> or C<remove>. It also has C<headers>
method that would return the same reference.

=item status_with_no_entity_body

  if (status_with_no_entity_body($res->[0])) { }

Returns true if the given status code doesn't have any Entity body in
HTTP response, i.e. it's 100, 101, 204 or 304.

=item inline_object

  my $o = Plack::Util::inline_object(
      write => sub { $h->push_write(@_) },
      close => sub { $h->push_shutdown },
  );
  $o->write(@stuff);
  $o->close;

Creates an instant object that can react to methods passed in the
constructor. Handy to create when you need to create an IO stream
object for input or errors.

=back

=cut



