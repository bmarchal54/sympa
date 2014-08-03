# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Mail;

use strict;
use warnings;
use DateTime;
use Encode qw();
use MIME::EncWords;
use POSIX qw();

use Sympa::Bulk;
use Conf;
use Log;
use Sympa::Message;
use Sympa::Robot;
use tools;
use tt2;

my $opensmtp = 0;
my $fh       = 'fh0000000000';    ## File handle for the stream.

my $max_arg = eval { POSIX::_SC_ARG_MAX(); };
if ($@) {
    $max_arg = 4096;
    printf STDERR <<'EOF', $max_arg;
Your system does not conform to the POSIX P1003.1 standard, or
your Perl system does not define the _SC_ARG_MAX constant in its POSIX
library. You must modify the smtp.pm module in order to set a value
for variable %s.

EOF
} else {
    $max_arg = POSIX::sysconf($max_arg);
}

my %pid = ();

my $send_spool;    ## for calling context

our $log_smtp;     # SMTP logging is enabled or not

### PUBLIC FUNCTIONS ###

####################################################
# public set_send_spool
####################################################
# set in global $send_spool, the concerned spool for
# sending message when it is not done by smtpto
#
# IN : $spool (+): spool concerned by sending
# OUT :
#
####################################################
sub set_send_spool {
    my $spool = pop;

    $send_spool = $spool;
}

####################################################
# public mail_file
####################################################
# send a tt2 file
#
#
# IN : -$filename(+) : tt2 filename (with .tt2) | ''
#      -$rcpt(+) : SCALAR |ref(ARRAY) : SMTP "RCPT To:" field
#      -$data(+) : used to parse tt2 file, ref(HASH) with keys :
#         -return_path(+) : SMTP "MAIL From:" field if send by smtp,
#                           "X-Sympa-From:" field if send by spool
#         -to : "To:" header field
#         -lang : tt2 language if $filename
#         -list :  ref(HASH) if $sign_mode = 'smime', keys are :
#            -name
#            -dir
#         -from : "From:" field if not a full msg
#         -subject : "Subject:" field if not a full msg
#         -replyto : "Reply-to:" field if not a full msg
#         -body  : body message if not $filename
#         -headers : ref(HASH) with keys are headers mail
#         -dkim : a set of parameters for appying DKIM signature
#            -d : d=tag
#            -i : i=tag (optionnal)
#            -selector : dkim dns selector
#            -key : the RSA private key
#      -$robot(+)
#      -$sign_mode :'smime' | '' | undef
#
# OUT : 1 | undef
####################################################
sub mail_file {
    Log::do_log('debug2', '(%s, %s, %s, %s, %s)', @_);
    my $robot                    = shift || '*';
    my $filename                 = shift;
    my $rcpt                     = shift;
    my $data                     = shift;
    my $return_message_as_string = shift;

    my $header_possible = $data->{'header_possible'};
    my $sign_mode       = $data->{'sign_mode'};

    my ($to, $message_as_string);

    my %header_ok;    # hash containing no missing headers
    my $existing_headers = 0;    # the message already contains headers

    ## We may receive a list a recepients
    if (ref($rcpt)) {
        unless (ref($rcpt) eq 'ARRAY') {
            Log::do_log('notice', 'Wrong type of reference for rcpt');
            return undef;
        }
    }

    ## Charset for encoding
    $data->{'charset'} ||= tools::lang2charset($data->{'lang'});

    ## TT2 file parsing
    #FIXME: Check TT2 parse error
    if ($filename =~ /\.tt2$/) {
        my $output;
        my @path = split /\//, $filename;
        tt2::parse_tt2($data, $path[$#path], \$output);
        $message_as_string .= join('', $output);
        $header_possible = 1;

    } else {    # or not
        $message_as_string .= $data->{'body'};
    }

    # Does the message include headers ?
    if ($data->{'headers'}) {
        foreach my $field (keys %{$data->{'headers'}}) {
            $field =~ tr/A-Z/a-z/;
            $header_ok{$field} = 1;
        }
    }
    if ($header_possible) {
        foreach my $line (split(/\n/, $message_as_string)) {
            last if ($line =~ /^\s*$/);
            if ($line =~ /^[\w-]+:\s*/) {    ## A header field
                $existing_headers = 1;
            } elsif ($existing_headers && ($line =~ /^\s/))
            {                                ## Following of a header field
                next;
            } else {
                last;
            }

            foreach my $header (
                qw(message-id date to from subject reply-to
                mime-version content-type content-transfer-encoding)
                ) {
                if ($line =~ /^$header\s*:/i) {
                    $header_ok{$header} = 1;
                    last;
                }
            }
        }
    }

    ## ADD MISSING HEADERS
    my $headers = "";

    unless ($header_ok{'message-id'}) {
        $headers .=
            sprintf("Message-Id: %s\n", tools::get_message_id($robot));
    }

    unless ($header_ok{'date'}) {
        ## Format current time.
        ## If setting local timezone fails, fallback to UTC.
        my $date =
            (eval { DateTime->now(time_zone => 'local') } || DateTime->now)
            ->strftime('%a, %{day} %b %Y %H:%M:%S %z');
        $headers .= sprintf "Date: %s\n", $date;
    }

    unless ($header_ok{'to'}) {
        # Currently, bare e-mail address is assumed.  Complex ones such as
        # "phrase" <email> won't be allowed.
        if (ref($rcpt)) {
            if ($data->{'to'}) {
                $to = $data->{'to'};
            } else {
                $to = join(",\n   ", @{$rcpt});
            }
        } else {
            $to = $rcpt;
        }
        $headers .= "To: $to\n";
    }
    unless ($header_ok{'from'}) {
        if (   !defined $data->{'from'}
            or $data->{'from'} eq 'sympa'
            or $data->{'from'} eq $data->{'conf'}{'sympa'}) {
            $headers .= 'From: '
                . tools::addrencode(
                $data->{'conf'}{'sympa'},
                $data->{'conf'}{'gecos'},
                $data->{'charset'}
                ) . "\n";
        } else {
            $headers .= "From: "
                . MIME::EncWords::encode_mimewords(
                Encode::decode('utf8', $data->{'from'}),
                'Encoding' => 'A',
                'Charset'  => $data->{'charset'},
                'Field'    => 'From'
                ) . "\n";
        }
    }
    unless ($header_ok{'subject'}) {
        $headers .= "Subject: "
            . MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $data->{'subject'}),
            'Encoding' => 'A',
            'Charset'  => $data->{'charset'},
            'Field'    => 'Subject'
            ) . "\n";
    }
    unless ($header_ok{'reply-to'}) {
        $headers .= "Reply-to: "
            . MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $data->{'replyto'}),
            'Encoding' => 'A',
            'Charset'  => $data->{'charset'},
            'Field'    => 'Reply-to'
            )
            . "\n"
            if ($data->{'replyto'});
    }
    if ($data->{'headers'}) {
        foreach my $field (keys %{$data->{'headers'}}) {
            $headers .=
                $field . ': '
                . MIME::EncWords::encode_mimewords(
                Encode::decode('utf8', $data->{'headers'}{$field}),
                'Encoding' => 'A',
                'Charset'  => $data->{'charset'},
                'Field'    => $field
                ) . "\n";
        }
    }
    unless ($header_ok{'mime-version'}) {
        $headers .= "MIME-Version: 1.0\n";
    }
    unless ($header_ok{'content-type'}) {
        $headers .=
            "Content-Type: text/plain; charset=" . $data->{'charset'} . "\n";
    }
    unless ($header_ok{'content-transfer-encoding'}) {
        $headers .= "Content-Transfer-Encoding: 8bit\n";
    }
    ## Determine what value the Auto-Submitted header field should take
    ## See http://www.tools.ietf.org/html/draft-palme-autosub-01
    ## the header filed can have one of the following values : auto-generated,
    ## auto-replied, auto-forwarded
    ## The header should not be set when wwsympa sends a command/mail to
    ## sympa.pl through its spool
    unless ($data->{'not_auto_submitted'} || $header_ok{'auto_submitted'}) {
        ## Default value is 'auto-generated'
        my $header_value = $data->{'auto_submitted'} || 'auto-generated';
        $headers .= "Auto-Submitted: $header_value\n";
    }

    unless ($existing_headers) {
        $headers .= "\n";
    }

    ## All these data provide mail attachements in service messages
    my @msgs = ();
    if (ref($data->{'msg_list'}) eq 'ARRAY') {
        @msgs =
            map { $_->{'msg'} || $_->{'full_msg'} } @{$data->{'msg_list'}};
    } elsif ($data->{'spool'}) {
        @msgs = @{$data->{'spool'}};
    } elsif ($data->{'msg'}) {
        push @msgs, $data->{'msg'};
    } elsif ($data->{'msg_path'} and open IN, '<' . $data->{'msg_path'}) {
        push @msgs, join('', <IN>);
        close IN;
    } elsif ($data->{'file'} and open IN, '<' . $data->{'file'}) {
        push @msgs, join('', <IN>);
        close IN;
    }

    my $listname = '';
    if (ref($data->{'list'}) eq "HASH") {    # compatibility
        $listname = $data->{'list'}{'name'};
    } elsif (ref($data->{'list'}) eq 'Sympa::List') {
        $listname = $data->{'list'}->{'name'};
    } elsif ($data->{'list'}) {
        $listname = $data->{'list'};
    }

    my $message = Sympa::Message->new(
        $headers . $message_as_string,
        #XXX list => $list,
        robot => $robot
    );
    return undef unless $message;

    unless ($message->reformat_utf8_message(\@msgs, $data->{'charset'})) {
        Log::do_log('err', 'Failed to reformat message');
    }

    ## Set it in case it was not set
    $data->{'return_path'} ||= Conf::get_robot_conf($robot, 'request');

    return $message->as_string if $return_message_as_string;

    ## SENDING
    return undef
        unless defined sending(
        'message'   => $message,
        'rcpt'      => $rcpt,
        'from'      => $data->{'return_path'},
        'robot'     => $robot,
        'listname'  => $listname,
        'priority'  => Conf::get_robot_conf($robot, 'sympa_priority'),
        'sign_mode' => $sign_mode,
        'use_bulk'  => $data->{'use_bulk'},
        'dkim'      => $data->{'dkim'},
        );
    return 1;
}

####################################################
# public mail_message
####################################################
# distribute a message to a list, Crypting if needed
#
# IN : -$message(+) : ref(Sympa::Message)
#      -$from(+) : message from
#      -$robot(+) : robot
#      -{verp=>[on|off]} : a hash to introduce verp parameters, starting just
#      on or off, later will probably introduce optionnal parameters
#      -@rcpt(+) : recepients
# OUT : -$numsmtp : number of sendmail process | undef
#
####################################################
sub mail_message {

    my %params      = @_;
    my $message     = $params{'message'};
    my $list        = $params{'list'};
    my $verp        = $params{'verp'};
    my @rcpt        = @{$params{'rcpt'}};
    my $dkim        = $params{'dkim_parameters'};
    my $tag_as_last = $params{'tag_as_last'};

    my $host  = $list->{'admin'}{'host'};
    my $robot = $list->{'domain'};

    unless (ref $message and $message->isa('Sympa::Message')) {
        Log::do_log('err', 'Invalid message parameter');
        return undef;
    }

    # normal return_path (ie used if verp is not enabled)
    my $from =
          $list->{'name'}
        . Conf::get_robot_conf($robot, 'return_path_suffix') . '@'
        . $host;

    Log::do_log(
        'debug',
        '(from: %s, file:%s, %s, verp->%s, %d rcpt, last: %s)',
        $from,
        $message->{'filename'},
        $message->{'smime_crypted'},
        $verp,
        $#rcpt + 1,
        $tag_as_last
    );
    return 0 unless @rcpt;

    my ($i, $j, $nrcpt);
    my $size    = 0;
    my $numsmtp = 0;

#    ## If message contain a footer or header added by Sympa  use the object
#    ## message else
#    ## Extract body from original file to preserve signature
#    ##FIXME: message may be encrypted.
#    my ($dummy, $msg_body) =
#        split /\r?\n\r?\n/, $message->as_string, 2;
#    $message->{'body_as_string'} = $msg_body;

    my %rcpt_by_dom;

    my @sendto;
    my @sendtobypacket;

    my $cmd_size =
        length(Conf::get_robot_conf($robot, 'sendmail')) + 1 +
        length(Conf::get_robot_conf($robot, 'sendmail_args')) +
        length(' -N success,delay,failure -V ') + 32 +
        length(" -f $from ");
    my $db_type = $Conf::Conf{'db_type'};

    while (defined($i = shift(@rcpt))) {
        my @k = reverse split /[\.@]/, $i;
        my @l = reverse split /[\.@]/, (defined $j ? $j : '@');

        my $dom;
        if ($i =~ /\@(.*)$/) {
            $dom = $1;
            chomp $dom;
        }
        $rcpt_by_dom{$dom} += 1;
        Log::do_log(
            'debug2',
            'Domain: %s; rcpt by dom: %s; limit for this domain: %s',
            $dom,
            $rcpt_by_dom{$dom},
            $Conf::Conf{'nrcpt_by_domain'}{$dom}
        );

        if (
            # number of recipients by each domain
            (   defined $Conf::Conf{'nrcpt_by_domain'}{$dom}
                and $rcpt_by_dom{$dom} >= $Conf::Conf{'nrcpt_by_domain'}{$dom}
            )
            or
            # number of different domains
            (       $j
                and $#sendto >= Conf::get_robot_conf($robot, 'avg')
                and lc "$k[0] $k[1]" ne lc "$l[0] $l[1]"
            )
            or
            # number of recipients in general, and ARG_MAX limitation
            (   $#sendto >= 0
                and (  $cmd_size + $size + length($i) + 5 > $max_arg
                    or $nrcpt >= Conf::get_robot_conf($robot, 'nrcpt'))
            )
            or
            # length of recipients field stored into bulkmailer table
            # (these limits might be relaxed by future release of Sympa)
            ($db_type eq 'mysql' and $size + length($i) + 5 > 65535)
            or
            ($db_type !~ /^(mysql|SQLite)$/ and $size + length($i) + 5 > 500)
            ) {
            undef %rcpt_by_dom;
            # do not replace this line by "push @sendtobypacket, \@sendto" !!!
            my @tab = @sendto;
            push @sendtobypacket, \@tab;
            $numsmtp++;
            $nrcpt = $size = 0;
            @sendto = ();
        }

        $nrcpt++;
        $size += length($i) + 5;
        push(@sendto, $i);
        $j = $i;
    }

    if ($#sendto >= 0) {
        $numsmtp++;
        my @tab = @sendto;
        # do not replace this line by push @sendtobypacket, \@sendto !!!
        push @sendtobypacket, \@tab;
    }

    return $numsmtp
        if (
        sendto(
            'message'  => $message,
            'from'     => $from,
            'rcpt'     => \@sendtobypacket,
            'listname' => $list->{'name'},
            'priority' => $list->{'admin'}{'priority'},
            'delivery_date' =>
                ($list->get_next_delivery_date || $message->{'date'} || time),
            'robot'       => $robot,
            'encrypt'     => $message->{'smime_crypted'},
            'use_bulk'    => 1,
            'verp'        => $verp,
            'dkim'        => $dkim,
            'merge'       => $list->{'admin'}{'merge_feature'},
            'tag_as_last' => $tag_as_last
        )
        );
    return undef;
}

####################################################
# public mail_forward
####################################################
# forward a message.
#
# IN : -$mmessage(+) : ref(Sympa::Message)
#      -$from(+) : message from
#      -$rcpt(+) : ref(SCALAR) | ref(ARRAY)  - recepients
#      -$robot(+) : robot
# OUT : 1 | undef
#
####################################################
sub mail_forward {
    my ($message, $from, $rcpt, $robot) = @_;
    Log::do_log('debug2', '(%s, %s)', $from, $rcpt);

    unless (ref $message eq 'Sympa::Message') {
        Log::do_log('err', 'Unexpected parameter type: %s', ref $message);
        return undef;
    }
    ## Add an Auto-Submitted header field according to
    ## http://www.tools.ietf.org/html/draft-palme-autosub-01
    $message->add_header('Auto-Submitted', 'auto-forwarded');

    unless (
        defined sending(
            'message'  => $message,
            'rcpt'     => $rcpt,
            'from'     => $from,
            'robot'    => $robot,
            'priority' => Conf::get_robot_conf($robot, 'request_priority'),
        )
        ) {
        Log::do_log('err', 'From %s impossible to send', $from);
        return undef;
    }
    return 1;
}

#####################################################################
# public reaper
#####################################################################
# Non blocking function called by : Sympa::Mail::smtpto(), sympa::main_loop
#  task_manager::INFINITE_LOOP scanning the queue,
#  bounced::infinite_loop scanning the queue,
# just to clean the defuncts list by waiting to any processes and
#  decrementing the counter.
#
# IN : $block
# OUT : $i
#####################################################################
sub reaper {
    my $block = shift;
    my $i;

    $block = 1 unless (defined($block));
    while (($i = waitpid(-1, $block ? POSIX::WNOHANG() : 0)) > 0) {
        $block = 1;
        if (!defined($pid{$i})) {
            Log::do_log('debug2', 'Reaper waited %s, unknown process to me',
                $i);
            next;
        }
        $opensmtp--;
        delete($pid{$i});
    }
    Log::do_log(
        'debug2',
        'Reaper unwaited pids: %s Open = %s',
        join(' ', sort keys %pid), $opensmtp
    );
    return $i;
}

### PRIVATE FUNCTIONS ###

####################################################
# sendto
####################################################
# send messages, S/MIME encryption if needed,
# grouped sending (or not if encryption)
#
# IN: $msg_header (+): message header : MIME::Head object
#     $msg_body (+): message body
#     $from (+): message from
#     $rcpt(+) : ref(SCALAR) | ref(ARRAY) - message recepients
#     $listname : use only to format return_path if VERP on
#     $robot(+) : robot
#     $encrypt : 'smime_crypted' | undef
#     $verp : 1| undef
#     $use_bulk : if defined,  send message using bulk
#
# OUT : 1 - call to sending
#
####################################################
sub sendto {
    my %params = @_;

    my $message     = $params{'message'};
    my $from        = $params{'from'};
    my $rcpt        = $params{'rcpt'};
    my $listname    = $params{'listname'};
    my $robot       = $params{'robot'};
    my $priority    = $params{'priority'};
    my $encrypt     = $params{'encrypt'};
    my $verp        = $params{'verp'};
    my $merge       = $params{'merge'};
    my $dkim        = $params{'dkim'};
    my $use_bulk    = $params{'use_bulk'};
    my $tag_as_last = $params{'tag_as_last'};

    Log::do_log(
        'debug',
        '(from: %s, listname: %s, encrypt: %s, verp: %s, priority = %s, last: %s, use_bulk: %s',
        $from,
        $listname,
        $encrypt,
        $verp,
        $priority,
        $tag_as_last,
        $use_bulk
    );

    my $delivery_date = $params{'delivery_date'};
    # if not specified, delivery tile is right now (used for sympa messages
    # etc)
    $delivery_date = time()
        unless $delivery_date;

    my $msg;

    if ($encrypt and $encrypt eq 'smime_crypted') {
        # encrypt message for each rcpt and send the message
        # this MUST be moved to the bulk mailer. This way, merge will be
        # applied after the SMIME encryption is applied ! This is a bug !
        foreach my $bulk_of_rcpt (@{$rcpt}) {
            foreach my $email (@{$bulk_of_rcpt}) {
                if ($email !~ /@/) {
                    Log::do_log('err',
                        'incorrect call for encrypt with incorrect number of recipient'
                    );
                    return undef;
                }

                my $new_message = $message->dup;
                unless ($new_message->smime_encrypt($email)) {
                    Log::do_log(
                        'err',
                        'Unable to encrypt message to list %s for recipient %s',
                        $listname,
                        $email
                    );
                    return undef;
                }
                unless (
                    sending(
                        'message'       => $new_message,
                        'rcpt'          => $email,
                        'from'          => $from,
                        'listname'      => $listname,
                        'robot'         => $robot,
                        'priority'      => $priority,
                        'delivery_date' => $delivery_date,
                        'use_bulk'      => $use_bulk,
                        'tag_as_last'   => $tag_as_last
                    )
                    ) {
                    Log::do_log('err', 'Failed to send encrypted message');
                    return undef;
                }
                $tag_as_last = 0;
            }
        }
    } else {
        my $result = sending(
            'message'       => $message,
            'rcpt'          => $rcpt,
            'from'          => $from,
            'listname'      => $listname,
            'robot'         => $robot,
            'priority'      => $priority,
            'delivery_date' => $delivery_date,
            'verp'          => $verp,
            'merge'         => $merge,
            'use_bulk'      => $use_bulk,
            'dkim'          => $dkim,
            'tag_as_last'   => $tag_as_last
        );
        return $result;
    }
    return 1;
}

####################################################
# sending
####################################################
# send a message using smpto function or puting it
# in spool according to the context
# Signing if needed
#
#
# IN : -$msg(+) : ref(MIME::Entity) | string - message to send
#      -$rcpt(+) : ref(SCALAR) | ref(ARRAY) - recepients
#       (for SMTP : "RCPT To:" field)
#      -$from(+) : for SMTP "MAIL From:" field , for
#        spool sending : "X-Sympa-From" field
#      -$robot(+) : robot
#      -$listname : listname | ''
#      -$sign_mode(+) : 'smime' | 'none' for signing
#      -$verp
#      -dkim : a hash for dkim parameters
#
# OUT : 1 - call to smtpto (sendmail) | 0 - push in spool
#           | undef
#
####################################################
sub sending {
    my %params           = @_;
    my $message          = $params{'message'};
    my $rcpt             = $params{'rcpt'};
    my $from             = $params{'from'};
    my $robot            = $params{'robot'};
    my $listname         = $params{'listname'};
    my $sign_mode        = $params{'sign_mode'};
    my $sympa_email      = $params{'sympa_email'};
    my $priority_message = $params{'priority'};
    my $priority_packet =
        Conf::get_robot_conf($robot, 'sympa_packet_priority');
    my $delivery_date = $params{'delivery_date'};
    $delivery_date = time() unless ($delivery_date);
    my $verp        = $params{'verp'};
    my $merge       = $params{'merge'};
    my $use_bulk    = $params{'use_bulk'};
    my $dkim        = $params{'dkim'};
    my $tag_as_last = $params{'tag_as_last'};
    my $sympa_file;
    my $fh;

    if ($sign_mode and $sign_mode eq 'smime') {
        unless ($message->smime_sign) {
            Log::do_log('notice', 'Unable to sign message from %s',
                $listname);
            return undef;
        }
    }

    my $verpfeature =
        ($verp and ($verp eq 'on' or $verp eq 'mdn' or $verp eq 'dsn'));
    my $trackingfeature;
    if ($verp and ($verp eq 'mdn' or $verp eq 'dsn')) {
        $trackingfeature = $verp;
    } else {
        $trackingfeature = '';
    }
    my $mergefeature = ($merge and $merge eq 'on');

    if ($use_bulk) {
        # in that case use bulk tables to prepare message distribution
        my $bulk_code = Sympa::Bulk::store(
            'message'          => $message,
            'rcpts'            => $rcpt,
            'from'             => $from,
            'robot'            => $robot,
            'listname'         => $listname,
            'priority_message' => $priority_message,
            'priority_packet'  => $priority_packet,
            'delivery_date'    => $delivery_date,
            'verp'             => $verpfeature,
            'tracking'         => $trackingfeature,
            'merge'            => $mergefeature,
            'dkim'             => $dkim,
            'tag_as_last'      => $tag_as_last,
        );

        unless (defined $bulk_code) {
            Log::do_log('err', 'Failed to store message for list %s',
                $listname);
            Sympa::Robot::send_notify_to_listmaster('bulk_error', $robot,
                {'listname' => $listname});
            return undef;
        }
    } elsif (defined $send_spool) {
        # in context wwsympa.fcgi do not send message to reciepients but copy
        # it to standard spool
        Log::do_log('debug', "NOT USING BULK");

        $sympa_email = Conf::get_robot_conf($robot, 'sympa');
        $sympa_file =
            "$send_spool/T.$sympa_email." . time . '.' . int(rand(10000));
        unless (open TMP, ">$sympa_file") {
            Log::do_log('notice', 'Cannot create %s: %s', $sympa_file, $!);
            return undef;
        }

        my $all_rcpt;
        if (ref($rcpt) eq 'SCALAR') {
            $all_rcpt = $$rcpt;
        } elsif (ref($rcpt) eq 'ARRAY') {
            $all_rcpt = join(',', @{$rcpt});
        } else {
            $all_rcpt = $rcpt;
        }

        $message->{'rcpt'}            = $all_rcpt;
        $message->{'envelope_sender'} = $from;
        $message->{'checksum'}        = tools::sympa_checksum($all_rcpt);

        printf TMP $message->to_string;
        close TMP;
        my $new_file = $sympa_file;
        $new_file =~ s/T\.//g;

        unless (rename $sympa_file, $new_file) {
            Log::do_log('notice', 'Cannot rename %s to %s: %s',
                $sympa_file, $new_file, $!);
            return undef;
        }
    } else {    # send it now
        Log::do_log('debug', "NOT USING BULK");
        *SMTP = smtpto($from, $rcpt, $robot);

        # Send message stripping Return-Path pseudo-header field.
        my $msg_string = $message->as_string;
        $msg_string =~ s/\AReturn-Path: (.*?)\n(?![ \t])//s;

        print SMTP $msg_string;
        unless (close SMTP) {
            Log::do_log('err', 'Could not close safefork to sendmail');
            return undef;
        }
    }
    return 1;
}

##############################################################################
# smtpto
##############################################################################
# Makes a sendmail ready for the recipients given as argument, uses a file
# descriptor in the smtp table which can be imported by other parties.
# Before, waits for number of children process < number allowed by sympa.conf
#
# IN : $from :(+) for SMTP "MAIL From:" field
#      $rcpt :(+) ref(SCALAR)|ref(ARRAY)- for SMTP "RCPT To:" field
#      $robot :(+) robot
#      $msgkey : a id of this message submission in notification table
# OUT : Sympa::Mail::$fh - file handle on opened file for ouput, for SMTP "DATA"
# field
#       | undef
#
##############################################################################
sub smtpto {
    my ($from, $rcpt, $robot, $msgkey, $sign_mode) = @_;

    Log::do_log('debug2',
        '(from: %s, rcpt:%s, robot:%s, msgkey:%s, sign_mode: %s)',
        $from, $rcpt, $robot, $msgkey, $sign_mode);

    unless ($from) {
        Log::do_log('err', 'Missing Return-Path');
    }

    if (ref($rcpt) eq 'SCALAR') {
        Log::do_log('debug2', '(%s, %s, %s)', $from, $$rcpt, $sign_mode);
    } elsif (ref($rcpt) eq 'ARRAY') {
        Log::do_log('debug2', '(%s, %s, %s)', $from, join(',', @{$rcpt}),
            $sign_mode);
    }

    my ($pid, $str);

    ## Escape "-" at beginning of recepient addresses
    ## prevent sendmail from taking it as argument

    if (ref($rcpt) eq 'SCALAR') {
        $$rcpt =~ s/^-/\\-/;
    } elsif (ref($rcpt) eq 'ARRAY') {
        my @emails = @$rcpt;
        foreach my $i (0 .. $#emails) {
            $rcpt->[$i] =~ s/^-/\\-/;
        }
    }

    ## Check how many open smtp's we have, if too many wait for a few
    ## to terminate and then do our job.

    Log::do_log('debug3', 'Open = %s', $opensmtp);
    while ($opensmtp > Conf::get_robot_conf($robot, 'maxsmtp')) {
        Log::do_log('debug3', 'Too many open SMTP (%s), calling reaper',
            $opensmtp);
        last if (reaper(0) == -1);    ## Blocking call to the reaper.
    }

    *IN  = ++$fh;
    *OUT = ++$fh;

    if (!pipe(IN, OUT)) {
        die "Unable to create a channel in smtpto: $!";
        ## No return
    }
    $pid = tools::safefork();
    $pid{$pid} = 0;

    my $sendmail      = Conf::get_robot_conf($robot, 'sendmail');
    my $sendmail_args = Conf::get_robot_conf($robot, 'sendmail_args');
    if ($msgkey) {
        $sendmail_args .= ' -N success,delay,failure -V ' . $msgkey;
    }
    if ($pid == 0) {

        close(OUT);
        open(STDIN, "<&IN");

        $from = '' if $from eq '<>';    # null sender
        if (!ref($rcpt)) {
            exec $sendmail, split(/\s+/, $sendmail_args), '-f', $from, $rcpt;
        } elsif (ref($rcpt) eq 'SCALAR') {
            exec $sendmail, split(/\s+/, $sendmail_args), '-f', $from, $$rcpt;
        } elsif (ref($rcpt) eq 'ARRAY') {
            exec $sendmail, split(/\s+/, $sendmail_args), '-f', $from, @$rcpt;
        }

        exit 1;                         ## Should never get there.
    }
    if ($log_smtp) {
        $str = "safefork: $sendmail $sendmail_args -f '$from' ";
        if (!ref($rcpt)) {
            $str .= $rcpt;
        } elsif (ref($rcpt) eq 'SCALAR') {
            $str .= $$rcpt;
        } else {
            $str .= join(' ', @$rcpt);
        }
        Log::do_log('notice', '%s', $str);
    }
    unless (close(IN)) {
        Log::do_log('err', 'Could not close safefork');
        return undef;
    }
    $opensmtp++;
    select(undef, undef, undef, 0.3)
        if ($opensmtp < Conf::get_robot_conf($robot, 'maxsmtp'));
    return ("Sympa::Mail::$fh");    ## Symbol for the write descriptor.
}

#XXX NOT USED
####################################################
# send_in_spool      : not used but if needed ...
####################################################
# send a message by putting it in global $send_spool
#
# IN : $rcpt (+): ref(SCALAR)|ref(ARRAY) - recepients
#      $robot(+) : robot
#      $sympa_email : for the file name
#      $XSympaFrom : for "X-Sympa-From" field
# OUT : $return->
#        -filename : name of temporary file
#         needing to be renamed
#        -fh : file handle opened for writing
#         on
####################################################
sub send_in_spool {
    my ($rcpt, $robot, $sympa_email, $XSympaFrom) = @_;
    Log::do_log('debug3', '(%s, %s, %s)', $XSympaFrom, $rcpt);

    unless ($sympa_email) {
        $sympa_email = Conf::get_robot_conf($robot, 'sympa');
    }

    unless ($XSympaFrom) {
        $XSympaFrom = Conf::get_robot_conf($robot, 'sympa');
    }

    my $sympa_file =
        "$send_spool/T.$sympa_email." . time . '.' . int(rand(10000));

    my $all_rcpt;
    if (ref($rcpt) eq "ARRAY") {
        $all_rcpt = join(',', @$rcpt);
    } else {
        $all_rcpt = $$rcpt;
    }

    unless (open TMP, ">$sympa_file") {
        Log::do_log('notice', 'Cannot create %s: %s', $sympa_file, $!);
        return undef;
    }

    printf TMP "X-Sympa-To: %s\n",       $all_rcpt;
    printf TMP "X-Sympa-From: %s\n",     $XSympaFrom;
    printf TMP "X-Sympa-Checksum: %s\n", tools::sympa_checksum($all_rcpt);

    my $return;
    $return->{'filename'} = $sympa_file;
    $return->{'fh'}       = \*TMP;

    return $return;
}

#DEPRECATED: Use Sympa::Message::reformat_utf8_message().
#sub reformat_message($;$$);

#DEPRECATED. Moved to Sympa::Message::_fix_utf8_parts as internal functioin.
#sub fix_part;

1;