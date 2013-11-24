package TAP::Parser::SourceHandler::Validator::W3C::HTML;
{
  $TAP::Parser::SourceHandler::Validator::W3C::HTML::VERSION = '0.01';
}

# ABSTRACT: TAP source handler for validating HTML via W3C validator

use LWP::UserAgent;
use Test::Builder;
use URI;
use TAP::Parser::IteratorFactory;
use WebService::Validator::HTML::W3C;
use WWW::Robot;

use base 'TAP::Parser::SourceHandler';

TAP::Parser::IteratorFactory->register_handler(__PACKAGE__);

use constant VALIDATOR => 'http://validator.w3.org/check';

# options and their defaults
my $crawl			= $ENV{TEST_W3C_HTML_CRAWL}			|| 0;
my $validator_uri	= $ENV{TEST_W3C_HTML_VALIDATOR_URI}	|| VALIDATOR;
my $timeout			= $ENV{TEST_W3C_HTML_TIMEOUT}		|| 5;
my $use_children	= $ENV{TEST_W3C_HTML_CHILDREN}		|| 0;

# given a type of test, attempt to parse it and let TAP::Harness know
# that we can handle it if it is a valid HTTP URI.

sub can_handle
{
	my $self	= shift;
	my $source	= shift;

	if ($source->meta->{is_scalar}) {
		my $uri = new URI ${ $source->raw };

		return 1 if $uri->isa('URI::http');
	}

	return 0;
}

sub make_iterator
{
	my $self	= shift;
	my $source	= shift;

	# TODO: Asynchronous validation with forking iterator...

	my $uri		= new URI ${ $source->raw };
	my $tap 	= $self->_check_uri($uri);
	my $iter	= new TAP::Parser::Iterator::Array [ split /\n+/, $tap ];

	return $iter;
}

sub _check_uri
{
	my $self = shift;
	my $root = shift;

	# setup our stuffs
	my $buffer		= '';
	my $trash		= '';
	my $builder		= Test::Builder->create;
	my $ua			= new LWP::UserAgent;
	my $spider		= new WWW::Robot USERAGENT => $ua;
	my $validator	= new WebService::Validator::HTML::W3C detailed => 1;

	$builder->output(\$buffer);
	$builder->failure_output(\$trash);

	$validator->validator_uri($validator_uri);

	$ua->timeout($timeout);

	my $spattrs = { map { /TEST_W3C_HTML_SPIDER_(.*)/ ? ($1 => $ENV{$_}) : () } keys %ENV };

	$spattrs->{NAME}	||= __PACKAGE__;
	$spattrs->{VERSION}	||= '1.0';
	$spattrs->{EMAIL}	||= 'root@localhost';

	$spider->setAttribute($_ => $spattrs->{$_}) foreach keys %$spattrs;

	$spider->addHook('follow-url-test' => sub {
		my $robot	= shift;
		my $hook	= shift;
		my $uri		= shift;

		return 1 if $uri eq $root;

		my $rel = $uri->rel($root);

		return 0 if not $crawl;
		return 0 if $rel->scheme;
		return 0 if $rel =~ /^\./;
		return 1;
	});

	my $handler = sub {
		my $robot	= shift;
		my $hook	= shift;
		my $uri		= shift;
		my $res		= shift;

		# XXX: We probably need to deal with redirects...

		my $test = $use_children ? $builder->child($uri) : $builder;

		$test->plan('no_plan') if $use_children;
		$test->ok($res->is_success, "fetch content for $uri");

		my $checked = $res->is_success
			? $validator->validate(string => $res->content)
			: 0;

		$test->note('ERROR: ' . $res->status_line)
			if $res->is_error;
		$test->note('ERROR: ' . $validator->validator_error)
			if $res->is_success and not $checked;

		$test->ok($checked, "validate content from $uri");
		$test->ok($checked && $validator->is_valid, "markup is valid for $uri");

		my $errors = $checked ? $validator->errors : [];

		$test->ok(0, sprintf "L%d:C%d %s", $_->line, $_->col, $_->msg)
			foreach @$errors;

		$test->finalize if $use_children;
	};

	# I planned on using the invoke-after-get hook, but the absence of
	# an invoke-on-* handler makes WWW::Robot croak.  So, we'll just use
	# an anonymous code ref and the same damn handler for both...

	$spider->addHook('invoke-on-contents' => $handler);
	$spider->addHook('invoke-on-get-error' => $handler);

	$spider->run($root);
	$builder->done_testing;

	return $buffer;
}

1;
