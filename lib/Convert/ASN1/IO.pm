
package Convert::ASN1;

# $Id: IO.pm,v 1.1 2000/05/03 12:24:53 gbarr Exp $

use strict;
use Socket;

BEGIN {
  local $SIG{__DIE__};
  eval { require bytes } and 'bytes'->import
}

sub asn_recv { # $socket, $buffer, $flags

  my $peer;
  my $buf;
  my $n = 128;
  my $pos = 0;
  my $depth = 0;
  my $len = 0;
  my($tmp,$tb,$lb);

  MORE:
  for(
    $peer = recv($_[0],$buf,$n,MSG_PEEK);
    defined $peer;
    $peer = recv($_[0],$buf,$n<<=1,MSG_PEEK)
  ) {

    if ($depth) { # Are we searching of "\0\0"

      next MORE unless 2+$pos <= length $buf;

      if(substr($buf,$pos,2) eq "\0\0") {
	unless (--$depth) {
	  $len = $pos + 2;
	  last MORE;
	}
      }
    }

    # If we can decode a tag and length we can detemine the length
    ($tb,$tmp) = asn_decode_tag(substr($buf,$pos));
    next MORE unless $tb || $pos+$tb < length $buf;

    if (ord(substr($buf,$pos+$tb,1)) == 0x80) {
      # indefinite length, grrr!
      $depth++;
      $pos += $tb + 1;
      redo MORE;
    }

    ($lb,$len) = asn_decode_length(substr($buf,$pos+$tb));

    if ($lb) {
      if ($depth) {
	$pos += $tb + $lb + $len;
	redo MORE;
      }
      else {
	$len += $tb + $lb + $pos;
	last MORE;
      }
    }
  }

  if (defined $peer) {
    if ($len > length $buf) {
      # Check we can read the whole element
      goto error
	unless defined($peer = recv($_[0],$buf,$len,MSG_PEEK));

      if ($len > length $buf) {
	# Cannot get whole element
	$_[1]='';
	return $peer;
      }
    }

    if ($_[2] & MSG_PEEK) {
      $_[1] =  substr($buf,$len);
    }
    elsif (!defined($peer = recv($_[0],$_[1],$len,0))) {
      goto error;
    }

    return $peer;
  }

error:
    $_[1] = undef;
}

sub asn_read { # $fh, $buffer, $offset

  # We need to read one packet, and exactly only one packet.
  # So we have to read the first few bytes one at a time, until
  # we have enough to decode a tag and a length. We then know
  # how many more bytes to read

  my $pos = 0;
  if ($_[2]) {
    if ($_[2] > length $_[1]) {
      require Carp;
      Carp::carp("Offset beyond end of buffer");
      return;
    }
    substr($_[1],$_[2]) = '';
  }
  else {
    $_[1] = '';
  }
  my $depth = 0;
  my $ch;
  my $mark;

  while(1) {
    unless ($pos < length $_[1]) {
      # The first byte is the tag
      sysread($_[0],$_[1],1,$pos) or
	  goto READ_ERR;
    }
    my $tch = ord(substr($_[1],$pos++,1));

    # Tag may be multi-byte
    if(($tch & 0x1f) == 0x1f) {
      do {
	my $ch;
	unless ($pos < length $_[1]) {
	  sysread($_[0], $_[1], 1, $pos) or
	      goto READ_ERR;
	}
	$ch = ord(substr($_[1],$pos++,1));
      } while($ch & 0x80);
    }

    # The next byte will be the first byte of the length
    unless ($pos < length $_[1]) {
      sysread($_[0], $_[1], 1, $pos) or
	goto READ_ERR;
    }
    $mark = $pos;
    my $lch = ord(substr($_[1],$pos++,1));

    # May be a multi-byte length
    if($lch & 0x80) {
      my $len = $ch & 0x7f;
      unless ($len) {
	$depth++;
	next;
      }
      while($len) {
	my $n = sysread($_[0], $_[0], $len, $pos) or
	  goto READ_ERR;
	$len -= $n;
	$pos += $n;
      }
    }
    elsif (!$lch && !$tch && $depth) {
      unless (--$depth) {
	last;
      }
    }

    my($lb,$len) = asn_decode_length(substr($_[1],$mark,$pos-$mark));

    while($len > 0) {
      my $got;

      goto READ_ERR
	  unless $got = sysread($_[0], $_[1],$len,$pos );

      $len -= $got;
      $pos += $got;
    }
    last unless $depth;
  }

  return length $_[1];

READ_ERR:
    $@ = "I/O Error $! " . CORE::unpack("H*",$_[0]);
    return undef;
}

sub asn_send { # $sock, $buffer, $flags, $to

  @_ == 4
    ? send($_[0],$_[1],$_[2],$_[3])
    : send($_[0],$_[1],$_[2]);
}

sub asn_write { # $sock, $buffer

  syswrite($_[0],$_[1], length $_[1]);
}

sub asn_get { # $fh

  my $fh = ref($_[0]) ? $_[0] : \($_[0]);
  my $href = \%{*$fh};

  $href->{'asn_buffer'} = '' unless exists $href->{'asn_buffer'};

  my $need = delete $href->{'asn_need'} || 0;
  while(1) {
    next if $need;
    my($tb,$tag) = asn_decode_tag($href->{'asn_buffer'}) or next;
    my($lb,$len) = asn_decode_length(substr($href->{'asn_buffer'},$tb,8)) or next;
    $need = $tb + $lb + $len;
  }
  continue {
    return substr($href->{'asn_buffer'},0,$need,'')
      if $need && $need <= length $href->{'asn_buffer'};

    my $get = $need > 1024 ? $need : 1024;

    sysread($_[0], $href->{'asn_buffer'}, $get, length $href->{'asn_buffer'})
      or return undef;
  }
}

sub asn_ready { # $fh

  my $fh = ref($_[0]) ? $_[0] : \($_[0]);
  my $href = \%{*$fh};

  return 0 unless exists $href->{'asn_buffer'};
  
  return $href->{'asn_need'} <= length $href->{'asn_buffer'}
    if exists $href->{'asn_need'};

  my($tb,$tag) = asn_decode_tag($href->{'asn_buffer'}) or return 0;
  my($lb,$len) = asn_decode_length(substr($href->{'asn_buffer'},$tb,8)) or return 0;

  $href->{'asn_need'} = $tb + $lb + $len;

  $href->{'asn_need'} <= length $href->{'asn_buffer'};
}

1;