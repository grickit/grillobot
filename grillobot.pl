use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin";
use IO::Socket;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Fcntl qw(F_SETFL O_NONBLOCK);

use wml;
$| = 1;

my $irc_channel = '##Gambot-lobby';


my @lobby_users;

sub connect_to_lobby {
  my $lobby_sock =
    new IO::Socket::INET(
      PeerAddr => "65.18.193.12",
      PeerPort => 15000,
      Proto => 'tcp')
    or die "Error while connecting to lobby.";
  print $lobby_sock pack('N',0) or die "Couldn't send handshake.";

  read $lobby_sock, my $first_packet, 4;
  my $connection_number = unpack('N',$first_packet);
  (length($first_packet) == 4) ? print "Lobby connection number is $connection_number\n" : die "Connection number is malformed.";
  return $lobby_sock;
}

sub connect_to_irc {
  my $irc_sock =
    new IO::Socket::INET(
      PeerAddr => 'chat.freenode.net',
      PeerPort => 6667,
      Proto => 'tcp')
    or die "Error while connecting to IRC.";
    print $irc_sock "NICK grillobot\x0D\x0A";
    print $irc_sock "USER Grillobot 8 * :Perl Grillobot\x0D\x0A";
    print $irc_sock "JOIN $irc_channel\x0D\x0A";
    return $irc_sock;
}

sub receive_lobby_message {
  #Returns 0 when there is nothing there.
  #Returns 1 when an error occured that necessitates reconnection.
  #Returns a message when there is a message.
  my $connection = shift;
  my ($packet, $unzipped_packet);
  my $buffer = '';
  my $bytes_read = sysread($connection, $buffer, 4);

  if(defined $bytes_read) {
    if($bytes_read == 0) {
      #If we read 0 bytes then the connection is dead
      print "Lobby connection died.\n";
      return 1;
    }

    elsif($bytes_read == 4) {
      #If we read 4 bytes then everything is fine.
      my $packet_length = unpack('N',$buffer);
      my $bytes_so_far = 0;

      while($bytes_so_far < $packet_length) {
        my $bytes_left = $packet_length - $bytes_so_far;
        $buffer = '';
        $bytes_read = sysread($connection,$buffer,$bytes_left);
        $bytes_so_far += length($buffer) if ($bytes_read == length($buffer));
        $packet .= $buffer;
      }

      gunzip \$packet => \$unzipped_packet or die "Gunzip fialed: $GunzipError";
      return $unzipped_packet;
    }

    else {
      #If we read something other than 0 or 4, then the header is malformed or the sysread failed.
      print "Failed to properly receive a packet and read its header.";
      return 1;
    }
  }
  else {
    #If we read an undefined number of bytes, that just means that there was nothing there.
    return 0;
  }
}

sub send_lobby_message {
  my ($connection, $outgoing_message) = @_;
  my $zipped_message;

  gzip \$outgoing_message => \$zipped_message or die "Gzip failed: $GzipError";
  my $header = pack('N',length $zipped_message);
  my $packet = $header . $zipped_message;
  print $connection $packet or die "Couldn't send message.";
}

sub receive_irc_message {
  #Returns 0 when there is nothing there.
  #Returns 1 when an error occured that necessitates reconnection.
  #Returns a message when there is a message.
  my ($connection, $buffer) = @_;
  my @full_messages = ();
  my $bytes_read = sysread($connection, $buffer, 1024, length($buffer));
  if (defined($bytes_read)) {
    if ($bytes_read == 0) {
      #If we read 0 bytes then the connection is dead
      print "IRC connection died.\n";
      return 1;
    }
    else {
      #If we read some bytes, then the connection is still alive.
      #Split the bytes into lines.
      my @buffered_lines = split(/\x0D\x0A/,$buffer);
      foreach my $buffed_line (@buffered_lines) {
        push(@full_messages,$buffed_line);
      }
      #If buffer doesn't end in a newline, then the last message received was cut off in the middle.
      #It needs to go back into our buffer.
      if ($buffer !~ /\x0D\x0A$/) {
        $buffer = $buffered_lines[-1];
        pop(@full_messages);
      }
      #If all of our messages are intact then clear the buffer.
      else {
        $buffer = '';
        return ($buffer, @full_messages);
      }
    }
  }
  else {
    #If we read an undefined number of bytes, that just means that there was nothing there.
    return 0;
  }
}

sub send_irc_message {
  my ($connection, $outgoing_message) = @_;
  print $connection "$outgoing_message\x0D\x0A";
}

sub process_lobby_message {
  my ($lobby_connection, $irc_connection, $incoming_message) = @_;
  my @base_tokens = tokenize($incoming_message);
  my $tree = populate_layer('data',@base_tokens);

  if(get_firstborn($tree,'version')) {
    send_lobby_message($lobby_connection,"[version]\nversion=\"1.9.5+svn\"\n[/version]");
  }

  elsif(get_firstborn($tree,'mustlogin')) {
    send_lobby_message($lobby_connection,"[login]\nusername=\"grillobot_\"\n[/login]");
  }

  if (my $child = get_firstborn($tree,'message')) {
    my $sender = $child->{'attr'}->{'sender'};
    my $message = $child->{'attr'}->{'message'};
    $message =~ s/[\n\r]+/ /g;
    $message =~ s/""/"/g;

    my $response = "\x02\x0303$sender>\x0F $message";
    if ($message =~ /^\/me/) {
      $message =~ s/^\/me *//;
      $response = "\x02\x0303$sender **\x0F $message \x02\x0303**\x0F";
    }
    send_irc_message($irc_connection,"PRIVMSG $irc_channel :$response");
  }
}

sub process_irc_message {
  my ($lobby_connection, $irc_connection, $incoming_message) = @_;

    my $valid_nick_characters = 'A-Za-z0-9[\]\\`_^{}|-'; #Valid character for a nick name
    my $valid_chan_characters = "#$valid_nick_characters"; #Valid characters for a channel name
    my $valid_human_sender_regex = "([.$valid_nick_characters]+)!~?([$valid_nick_characters]+)@(.+?)"; #Matches nick!~user@hostname

  #Ingnore motd spam
  if ($incoming_message =~ /^.+\.freenode\.net 372 grillobot_ :- .+$/) { }

  #You must respond to pings on IRC.
  elsif ($incoming_message =~ /^PING(.*)$/i) {
    send_irc_message($irc_connection,"PONG $1");
  }

  elsif ($incoming_message =~ /^:$valid_human_sender_regex PRIVMSG $irc_channel :(.+)$/) {
    my ($sender, $account, $hostname, $message) = ($1, $2, $3, $4);
    send_lobby_message($lobby_connection,"[message]\nmessage=\"$sender> $message\"\n[/message]");
  }

  elsif ($incoming_message =~ /^:$valid_human_sender_regex JOIN :$irc_channel$/) {
    my ($sender, $account, $hostname) = ($1, $2, $3);
    send_lobby_message($lobby_connection,"[message]\nmessage=\"$sender has joined IRC.\"\n[/message]");
  }

  elsif ($incoming_message =~ /^:$valid_human_sender_regex PART $irc_channel?:?(.+)?$/) {
    my ($sender, $account, $hostname, $message) = ($1, $2, $3, $4);
    send_lobby_message($lobby_connection,"[message]\nmessage=\"$sender has left IRC.\"\n[/message]");
  }

  elsif ($incoming_message =~ /^:$valid_human_sender_regex QUIT ?:?(.+)?$/) {
    my ($sender, $account, $hostname, $message) = ($1, $2, $3, $4);
    send_lobby_message($lobby_connection,"[message]\nmessage=\"$sender has left IRC.\"\n[/message]");
  }
}

#my $lobby_sock = connect_to_lobby();
#fcntl($lobby_sock, F_SETFL(), O_NONBLOCK());
#my $irc_sock = connect_to_irc();
#fcntl($irc_sock, F_SETFL(), O_NONBLOCK());
#my $irc_buffer = '';

#while(defined select(undef,undef,undef,0.25)) {
#  if(my $lobby_packet = receive_lobby_message($lobby_sock)) {
#    process_lobby_message($lobby_sock, $irc_sock, $lobby_packet);
#  }

#  elsif(my ($irc_buffer, @messages) = receive_irc_message($irc_sock, $irc_buffer)) {
#    foreach my $current_message (@messages) {
#      process_irc_message($lobby_sock,$irc_sock,$current_message);
#    }
#  }
#}

run_test();