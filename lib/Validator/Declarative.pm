#!/usr/bin/env perl
use strict;
use warnings;

package Validator::Declarative;
{
  $Validator::Declarative::VERSION = '1.20130718.2341';
}

# ABSTRACT: Declarative parameters validation

use Error qw/ :try /;
use Module::Load;
use Readonly;

Readonly my $RULE_CONSTRAINT => 'constraint';
Readonly my $RULE_CONVERTER  => 'converter';
Readonly my $RULE_TYPE       => 'type';

sub register_constraint { _register_rules( $RULE_CONSTRAINT => \@_ ) }
sub register_converter  { _register_rules( $RULE_CONVERTER  => \@_ ) }
sub register_type       { _register_rules( $RULE_TYPE       => \@_ ) }

sub validate {
    my $params      = shift;
    my $definitions = shift;

    throw Error::Simple('invalid "params"')
        if ref($params) ne 'ARRAY';

    throw Error::Simple('invalid rules definitions')
        if ref($definitions) ne 'ARRAY';

    throw Error::Simple('count of params does not match count of rules definitions')
        if scalar(@$params) * 2 != scalar(@$definitions);

    throw Error::Simple('extra parameters')
        if @_;

    # one-level copy to not harm input parameters
    $params      = [@$params];
    $definitions = [@$definitions];

    my ( @errors, @output );
    while (@$params) {
        my $value = shift @$params;
        my $name  = shift @$definitions;
        my $rules = shift @$definitions;

        try {
            my $normalized_rules = _normalize_rules($rules);
            my $is_optional = _check_constraints( $value, $normalized_rules->{constraints} );
            $value = _run_convertors( $value, $normalized_rules->{converters}, $is_optional );
            _check_types( $value, $normalized_rules->{types} ) if defined($value) && !$is_optional;
            push @output, $value;
        }
        catch Error with {
            my $error             = shift;
            my $stringified_value = $value;
            $stringified_value = '<undef>' if !defined($stringified_value);
            $stringified_value = 'empty string' if $stringified_value eq '';
            $stringified_value =~ s/[^[:print:]]/./g;
            push @errors, sprintf( '%s: %s %s', $name, $stringified_value, $error->{-text} );
            push @output, undef;
        };
    }

    throw Error::Simple( join "\n" => @errors ) if @errors;

    return @output;
}

#
# INTERNALS
#
my $registered_rules        = {};
my $registered_name_to_kind = {};

# stubs for successful/unsuccesfull validations
sub _validate_pass { my ($input) = @_; return $input; }
sub _validate_fail { throw Error::Simple('failed permanently'); }

sub _normalize_rules {
    my $rules = shift;

    my $types       = {};
    my $converters  = {};
    my $constraints = {};

    # if there were only one rule - normalize to arrayref anyway
    $rules = [$rules] if ref($rules) ne 'ARRAY';

    #
    # each rule can be string (name of simple rule) or arrayref/hashref (parametrized rule)
    # let's normalize them - convert everything to arrayrefs
    # hashrefs should not contain more than one key/value pair
    #
    # validator parameters (all items in resulting arrayref, except first one) should
    # left intact, i.e. if parameter was scalar, it should be saved as scalar,
    # arrayref as arrayref, and so on - there is no place for any conversion
    #
    foreach my $rule (@$rules) {
        my $result;

        if ( ref($rule) eq 'ARRAY' ) {
            $result = $rule;
        }
        elsif ( ref($rule) eq 'HASH' ) {
            throw Error::Simple('hashref rule should have exactly one key/value pair')
                if keys %$rule > 1;
            $result = [%$rule];
        }
        elsif ( ref($rule) ) {
            throw Error::Simple( 'rule definition can\'t be reference to ' . ref($rule) );
        }
        else {
            ## should be plain string, so this is name of simple rule
            $result = [$rule];
        }

        my $name   = $result->[0];
        my $params = $result->[1];

        throw Error::Simple("rule $name is not registered")
            if !exists $registered_name_to_kind->{$name};

        throw Error::Simple("rule $name can accept not more than one parameter")
            if @$result > 2;

        my $rule_kind = $registered_name_to_kind->{$name};

        if ( $rule_kind eq $RULE_TYPE ) {
            $types->{$name} = $params;
        }
        elsif ( $rule_kind eq $RULE_CONVERTER ) {
            $converters->{$name} = $params;
        }
        elsif ( $rule_kind eq $RULE_CONSTRAINT ) {
            $constraints->{$name} = $params;
        }
        else {
            ## we should never pass here
            die("internal error: rule $name is registered as $rule_kind");
        }
    }

    return {
        types       => $types,
        converters  => $converters,
        constraints => $constraints,
    };
}

sub _check_constraints {
    my ( $value, $constraints ) = @_;

    # check for built-in constraints (required/optional/not_empty)
    my $is_required = exists $constraints->{required};
    my $is_optional = exists $constraints->{optional};

    throw Error::Simple('both required and optional are specified')
        if $is_required && $is_optional;

    if ($is_optional) {
        delete $constraints->{optional};
        ## there is nothing else to do
    }
    else {
        delete $constraints->{required};

        throw Error::Simple('parameter is required')
            if !defined($value);

        # check for all non-built-in constraints
        while ( my ( $rule_name, $rule_params ) = each %$constraints ) {
            my $code = $registered_rules->{$RULE_CONSTRAINT}{$rule_name};
            $code->( $value, $rule_params );
        }
    }

    return $is_optional;
}

sub _run_convertors {
    my ( $value, $converters, $is_optional ) = @_;

    # process "default" converter (if any)
    my $has_default = exists $converters->{default};

    throw Error::Simple('"default" specified without "optional"')
        if $has_default && !$is_optional;

    if ($has_default) {
        $value = $converters->{default} if !defined($value);
        delete $converters->{default};
    }

    throw Error::Simple('there is more than one converter, except "default"')
        if keys %$converters > 1;

    # process non-"default" converter (if any)
    if (%$converters) {
        my ( $rule_name, $rule_params ) = %$converters;
        my $code = $registered_rules->{$RULE_CONVERTER}{$rule_name};
        $value = $code->( $value, $rule_params );
    }

    return $value;
}

sub _check_types {
    my ( $value, $types ) = @_;

    # first successful check wins, all others will not be checked
    return if !%$types || exists( $types->{any} ) || exists( $types->{string} );

    my $saved_error;
    while ( my ( $rule_name, $rule_params ) = each %$types ) {
        my $last_error;
        try {
            my $code = $registered_rules->{$RULE_TYPE}{$rule_name};
            $code->( $value, $rule_params );
        }
        catch Error with {
            $last_error = $saved_error = shift;
        };
        return if !$last_error;
    }

    if ( scalar keys %$types == 1 ) {
        throw $saved_error;
    }
    else {
        throw Error::Simple('does not satisfy any type');
    }
}

sub _register_rules {
    my $kind  = shift;
    my $rules = shift;

    throw Error::Simple(qq|Can't register rule of kind <$kind>|)
        if $kind ne $RULE_TYPE
        && $kind ne $RULE_CONVERTER
        && $kind ne $RULE_CONSTRAINT;

    $rules = {@$rules};

    while ( my ( $name, $code ) = each %$rules ) {

        throw Error::Simple(qq|Can't register rule without name|)
            if !defined($name) || !length($name);

        throw Error::Simple(qq|Rule <$name> already registered|)
            if exists( $registered_name_to_kind->{$name} );

        $registered_rules->{$kind}{$name} = $code;
        $registered_name_to_kind->{$name} = $kind;
    }
}

sub _register_default_constraints {
    ## built-in constraints implemented inline
    $registered_name_to_kind->{$_} = $RULE_CONSTRAINT for qw/ required optional not_empty /;
}

sub _register_default_converters {
    ## built-in converters implemented inline
    $registered_name_to_kind->{$_} = $RULE_CONVERTER for qw/ default /;
}

sub _register_default_types {
    ## built-in types implemented inline
    $registered_name_to_kind->{$_} = $RULE_TYPE for qw/ any string /;
}

sub _load_base_rules {
    for my $plugin (qw/ SimpleType ParametrizedType /) {
        my $module = __PACKAGE__ . '::Rules::' . $plugin;
        load $module;
    }
}

_register_default_constraints();
_register_default_converters();
_register_default_types();
_load_base_rules();


1;    # End of Validator::Declarative


__END__
=pod

=head1 NAME

Validator::Declarative - Declarative parameters validation

=head1 VERSION

version 1.20130718.2341

=head1 SYNOPSIS

    sub MakeSomethingCool {
        my $serialized_parameters;
        my ( $ace_id, $upm_id, $year, $week, $timestamp_ms ) = Validator::Declarative->validate(
            \@_ => [
                ace_id         => 'id',
                upm_id         => 'id',
                year           => 'year',
                week           => 'week',
                timestamp_ms   => [ 'to_msec', 'mdy', 'timestamp' ],
            ],
        );

        # here all parameters are validated
        # .......

    }

=head1 DESCRIPTION

=head1 METHODS

=head2 validate(\@params => \@rules)

=head2 register_type( $name => $code, ...)

=head2 register_converter( $name => $code, ...)

=head2 register_constraint( $name => $code, ...)

=head1 SEE ALSO

Inspired by Validator::LIVR - L<https://github.com/koorchik/Validator-LIVR>

=head1 AUTHOR

Oleg Kostyuk, C<< <cub at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to Github L<https://github.com/cub-uanic/Validator-Declarative>

=head1 AUTHOR

Oleg Kostyuk <cub@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by Oleg Kostyuk.

This is free software, licensed under:

  The (three-clause) BSD License

=cut

