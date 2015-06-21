##############################################################################
# $Id$
#
#     70_Telegram.pm
#
#     This file is part of Fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with Fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#	
#  Telegram (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem
#
# This module handles receiving and sending messages to the messaging service telegram (see https://telegram.org/)
# It works ONLY with a running telegram-cli (unofficial telegram cli client) --> see here https://github.com/vysheng/tg
# telegram-cli needs to be configured and running as daemon local on the fhem host
#
##############################################################################
# 0.0 2015-06-16 Started
#
#   Build structure for module
#   telegram-cli for operation
#   Basic DevIo handling
#   Attributes etc
#   Allow message sending to defaultpeer
#   basic telegram_read for only putting message into reading
# 0.1 2015-06-17 Initial Version
#   
#   General command handling analyzing results
#   _write function
#   handle initialization (client write / main session) in DoInit
#   allow host 
#   shutdown function added to send quit on connection
#   Telegram_read
#   handle readings
#   document cli command
#   document attr/set/get
#   documentation on limitations
# 0.2a 2015-06-19 Running basic version with send and receive
#   corrections and stabilizations on message receive
# 0.2b 2015-06-20 Update 
#
#   works after rereadcfg
#   DoCommand reimplemented
#   Cleaned also the read function
#   add raw as set command to execute a raw command on the telegram-cli 
#   get msgid now implemented
#   renamed msg set/get into message (set) and msgById (get)
#   added readyfn for handling remaining internal 
# 0.3 2015-06-20 stabilized
#   
#   sent to any peer with set messageTo 
#   reopen connection is done automatically through DevIo
#   document telegram-cli command in more detail
#   added zDebug set for internal cleanup work (currently clean remaining)
#   parse also secret chat messages
#   request default peer to be given with underscore not space 
#   Read will parse now all remaining messages and run multiple bulk updates in a row for each mesaage one
#   lastMessage moved from Readings to Internals
#   BUG resolved: messages are split wrongly (A of ANSWER might be cut)
#   updated git hub link
#   allow secret chat / new attr defaultSecret to send messages to defaultPeer via secret chat
# 0.4 2015-06-22 SecretChat and general extensions and cleanup
#   
#
##############################################################################
# TODO 
# - find way to enforce the handling of remaining messages
# - extend telegram to restrict only to allowed peers
# - handle Attr: lastMsgId
# - read all unread messages from default peer on init
#
##############################################################################
# Ideas / Future
# - support unix socket also instead of port only
# - allow multi parameter set for set <device> <peer> 
# - start local telegram-cli as subprocess
# - allow registration and configuration from module
# - handled online / offline messages
# - support presence messages
#
##############################################################################
#	
# Internals
#   - Internal: sentMsgText
#   - Internal: sentMsgResult
#   - Internal: sentMsgPeer
#   - Internal: sentMsgSecure
#   - Internal: REMAINING - used for storing messages received intermediate
#   - Internal: lastmessage - last message handled in Read function
#   - Internal: sentMsgId???
# 
##############################################################################

package main;

use strict;
use warnings;
use DevIo;

use Scalar::Util qw(reftype looks_like_number);

#########################
# Forward declaration
sub Telegram_Define($$);
sub Telegram_Undef($$);

sub Telegram_Set($@);
sub Telegram_Get($@);

sub Telegram_Read($);
sub Telegram_Write($$);
sub Telegram_Parse($$$);


#########################
# Globals
my %sets = (
	"message" => "textField",
	"secretChat" => undef,
	"messageTo" => "textField",
	"raw" => "textField",
	"zDebug" => "textField"
);

my %gets = (
	"msgById" => "textField"
);




#####################################
# Initialize is called from fhem.pl after loading the module
#  define functions and attributed for the module and corresponding devices

sub Telegram_Initialize($) {
	my ($hash) = @_;

	require "$attr{global}{modpath}/FHEM/DevIo.pm";

	$hash->{ReadFn}     = "Telegram_Read";
	$hash->{WriteFn}    = "Telegram_Write";
	$hash->{ReadyFn}    = "Telegram_Ready";

	$hash->{DefFn}      = "Telegram_Define";
	$hash->{UndefFn}    = "Telegram_Undef";
	$hash->{GetFn}      = "Telegram_Get";
	$hash->{SetFn}      = "Telegram_Set";
  $hash->{ShutdownFn} = "Telegram_Shutdown"; 
	$hash->{AttrFn}     = "Telegram_Attr";
	$hash->{AttrList}   = "lastMsgId defaultPeer defaultSecret:0,1 ".
						$readingFnAttributes;
	
}


######################################
#  Define function is called for actually defining a device of the corresponding module
#  For telegram this is mainly the name and information about the connection to the telegram-cli client
#  data will be stored in the hash of the device as internals
#  
sub Telegram_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t]+", $def);
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Define $name: called ";

  my $errmsg = '';
  
  # Check parameter(s)
  if( int(@a) != 3 ) {
    $errmsg = "syntax error: define <name> Telegram <port> ";
    Log3 $name, 3, "Telegram $name: " . $errmsg;
    return $errmsg;
  }
  
  if ( $a[2] =~ /^([[:alnum:]][[:alnum:]-]*):[[:digit:]]+$/ ) {
    $hash->{DeviceName} = $a[2];
  } elsif ( $a[2] =~ /:/ ) {
    $errmsg = "specify valid hostname and numeric port: define <name> Telegram  [<hostname>:]<port> ";
    Log3 $name, 3, "Telegram $name: " . $errmsg;
    return $errmsg;
  } elsif (! looks_like_number($a[2])) {
    $errmsg = "port needs to be numeric: define <name> Telegram  [<hostname>:]<port> ";
    Log3 $name, 3, "Telegram $name: " . $errmsg;
    return $errmsg;
  } else {
    $hash->{DeviceName} = "localhost:$a[2]";
  }
  
  $hash->{TYPE} = "Telegram";

  $hash->{Port} = $a[2];
  $hash->{Protocol} = "telnet";

  # close old dev
  Log3 $name, 5, "Telegram_Define $name: handle DevIO ";
  DevIo_CloseDev($hash);

  my $ret = DevIo_OpenDev($hash, 0, "Telegram_DoInit");

  ### initialize timer for connectioncheck
  #$hash->{helper}{nextConnectionCheck} = gettimeofday()+120;

  Log3 $name, 5, "Telegram_Define $name: done with ".(defined($ret)?$ret:"undef");
  return $ret; 
}

#####################################
#  Undef function is corresponding to the delete command the opposite to the define function 
#  Cleanup the device specifically for external ressources like connections, open files, 
#		external memory outside of hash, sub processes and timers
sub Telegram_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Undef $name: called ";

  RemoveInternalTimer($hash);
  # deleting port for clients
  foreach my $d (sort keys %defs) {
    if(defined($defs{$d}) &&
		defined($defs{$d}{IODev}) &&
		$defs{$d}{IODev} == $hash) {
      Log3 $hash, 3, "Telegram $name: deleting port for $d";
      delete $defs{$d}{IODev};
    }
  }
  Log3 $name, 5, "Telegram_Undef $name: close devio ";
  
  DevIo_CloseDev($hash);

  Log3 $name, 5, "Telegram_Undef $name: done ";
  return undef;
}

####################################
# set function for executing set operations on device
sub Telegram_Set($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 5, "Telegram_Set $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "Telegram_Set: No value specified for set" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;

  Log3 $name, 5, "Telegram_Set $name: Processing Telegram_Set( $cmd )";

	if(!exists($sets{$cmd})) {
		my @cList;
		foreach my $k (sort keys %sets) {
			my $opts = undef;
			$opts = $sets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		} # end foreach

		return "Telegram_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

  my $ret = undef;
  
	if($cmd eq 'message') {
    if ( $numberOfArgs < 2 ) {
      return "Telegram_Set: Command $cmd, no text specified";
    }
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "Telegram_Set: Command $cmd, requires defaultPeer being set";
    }
    # should return undef if succesful
    Log3 $name, 5, "Telegram_Set $name: start message send ";
    my $arg = join(" ", @args );
    $ret = Telegram_SendMessage( $hash, $peer, $arg );

	} elsif($cmd eq 'messageTo') {
    if ( $numberOfArgs < 3 ) {
      return "Telegram_Set: Command $cmd, need to specify peer and text ";
    }

    # should return undef if succesful
    my $peer = shift @args;
    my $arg = join(" ", @args );

    Log3 $name, 5, "Telegram_Set $name: start message send ";
    $ret = Telegram_SendMessage( $hash, $peer, $arg );

  } elsif($cmd eq 'raw') {
    if ( $numberOfArgs < 2 ) {
      return "Telegram_Set: Command $cmd, no raw command specified";
    }

    my $arg = join(" ", @args );
    Log3 $name, 5, "Telegram_Set $name: start rawCommand :$arg: ";
    $ret = Telegram_DoCommand( $hash, $arg, undef );
  } elsif($cmd eq 'secretChat') {
    if ( $numberOfArgs > 1 ) {
      return "Telegram_Set: Command $cmd, no parameters allowed";
    }
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "Telegram_Set: Command $cmd, requires defaultPeer being set";
    }
    Log3 $name, 5, "Telegram_Set $name: initiate secret chat with :$peer: ";
    my $statement = "create_secret_chat ".$peer;
    $ret = Telegram_DoCommand( $hash, $statement, undef );
  } elsif($cmd eq 'zDebug') {
    Log3 $name, 5, "Telegram_Set $name: start debug option ";
#    delete( $hash->{READINGS}{lastmessage} );
#    delete( $hash->{READINGS}{prevMsgSecret} );
    $hash->{REMAINING} =  '';
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 5, "Telegram_Set $name: $cmd done succesful: ";
  } else {
    Log3 $name, 5, "Telegram_Set $name: $cmd failed with :$ret: ";
  }
  return $ret
}

#####################################
# get function for gaining information from device
sub Telegram_Get($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 5, "Telegram_Get $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "Telegram_Get: No value specified for get" if ( $numberOfArgs < 1 );

	my $cmd = $args[0];
  my $arg = ($args[1] ? $args[1] : "");

  Log3 $name, 5, "Telegram_Get $name: Processing Telegram_Get( $cmd )";

	if(!exists($gets{$cmd})) {
		my @cList;
		foreach my $k (sort keys %gets) {
			my $opts = undef;
			$opts = $sets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		} # end foreach

		return "Telegram_Get: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

  
  my $ret = undef;
  
	if($cmd eq 'msgById') {
    if ( $numberOfArgs != 2 ) {
      return "Telegram_Set: Command $cmd, no msg id specified";
    }
    Log3 $name, 5, "Telegram_Get $name: get message for id $arg";

    # should return undef if succesful
   $ret = Telegram_GetMessage( $hash, $arg );
  }
  
  Log3 $name, 5, "Telegram_Get $name: done with $ret: ";

  return $ret
}

##############################
# attr function for setting fhem attributes for the device
sub Telegram_Attr(@) {
	my ($cmd,$name,$aName,$aVal) = @_;
	my $hash = $defs{$name};

  Log3 $name, 5, "Telegram_Attr $name: called ";

	return "\"Telegram_Attr: \" $name does not exist" if (!defined($hash));

  Log3 $name, 5, "Telegram_Attr $name: $cmd  on $aName to $aVal";
  
	# $cmd can be "del" or "set"
	# $name is device name
	# aName and aVal are Attribute name and value
	if ($cmd eq "set") {
		if($aName eq 'lastMsgId') {
			return "Telegram_Attr: value must be >=0 " if( $aVal < 0 );
		}

		if ($aName eq 'lastMsgId') {
			$attr{$name}{'lastMsgId'} = $aVal;

		} elsif ($aName eq 'defaultPeer') {
			$attr{$name}{'defaultPeer'} = $aVal;

    }
	}

	return undef;
}

######################################
#  Shutdown function is called on shutdown of server and will issue a quite to the cli 
sub Telegram_Shutdown($) {

	my ( $hash ) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Attr $name: called ";

  # First needs send an empty line and read all returns away
  my $buf = Telegram_DoCommand( $hash, '', undef );

  # send a quit but ignore return value
  $buf = Telegram_DoCommand( $hash, '', undef );
  Log3 $name, 5, "Telegram_Shutdown $name: Done quit with return :".(defined($buf)?$buf:"undef").": ";
  
  return undef;
}

#####################################
sub Telegram_Ready($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Ready $name: called ";

  if($hash->{STATE} eq "disconnected") {
    Log3 $name, 5, "Telegram $name: Telegram_Ready() state: disconnected -> DevIo_OpenDev";
    return DevIo_OpenDev($hash, 1, "Telegram_DoInit");
  }

  return undef if( ! defined($hash->{REMAINING}) );

  return ( length($hash->{REMAINING}) );
}
   
#####################################
# _Read is called when data is available on the corresponding file descriptor 
# data to be read must be collected in hash until the data is complete
# Parse only one message at a time to be able that readingsupdates will be sent out
# to be deleted
#ANSWER 65
#User First Last online (was online [2015/06/18 23:53:53])
#
#ANSWER 41
#55 [23:49]  First Last >>> test 5
#
#ANSWER 66
#User First Last offline (was online [2015/06/18 23:49:08])
#
#mark_read First_Last
#ANSWER 8
#SUCCESS
#
#ANSWER 60
#806434894237732045 [16:51]  !_First_Last Â»Â»Â» Aaaa
#
#ANSWER 52
#Secret chat !_First_Last updated access_hash
#
#ANSWER 57
# Encrypted chat !_First_Last is now in wait state
#
#ANSWER 47
#Secret chat !_First_Last updated status
#
#ANSWER 88
#-6434729167215684422 [16:50]  !_First_Last First Last updated layer to 23
#
#ANSWER 63
#-9199163497208231286 [16:50]  !_First_Last Â»Â»Â» Hallo
#
sub Telegram_Read($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Read $name: called ";

  # Read new data
	my $buf = DevIo_SimpleRead($hash);
  if ( $buf ) {
    Log3 $name, 5, "Telegram_Read $name: New read :$buf: ";
  }
  
  # append remaining content to buf
  $hash->{REMAINING} = '' if( ! defined($hash->{REMAINING}) );
  $buf = $hash->{REMAINING}.$buf;

  Log3 $name, 5, "Telegram_Read $name: Full buffer :$buf: ";

  my ( $msg, $rawMsg );
  
  while ( length( $buf ) > 0 ) {
  
    ( $msg, $rawMsg, $buf ) = Telegram_getNextMessage( $hash, $buf );
    if ( length($msg) == 0 ) {
      # No msg found (garbage in the buffer) so try again
      ( $msg, $rawMsg, $buf ) = Telegram_getNextMessage( $hash, $buf );
    }

    Log3 $name, 5, "Telegram_Read $name: parsed a message :".$msg.": ";
    Log3 $name, 5, "Telegram_Read $name: and remaining :".$buf.": ";

    # Do we have a message found
    if (length( $msg )>0) {
      Log3 $name, 5, "Telegram_Read $name: message in buffer :$msg:";
      $hash->{lastmessage} = $msg;

      #55 [23:49]  First Last >>> test 5
      # Ignore all none received messages  // final \n is already removed
      if ( $msg =~ /^(\d+)\s\[[^\]]+\]\s+([^\s][^>]*)\s>>>\s(.*)$/s  ) {
        my $mid = $1;
        my $mpeer = $2;
        my $mtext = $3;
        Log3 $name, 5, "Telegram_Read $name: Found message $mid from $mpeer :$mtext:";
   
        readingsBeginUpdate($hash);

        readingsBulkUpdate($hash, "prevMsgId", $hash->{READINGS}{msgId}{VAL});				
        readingsBulkUpdate($hash, "prevMsgPeer", $hash->{READINGS}{msgPeer}{VAL});				
        readingsBulkUpdate($hash, "prevMsgText", $hash->{READINGS}{msgText}{VAL});				

        readingsBulkUpdate($hash, "msgId", $mid);				
        readingsBulkUpdate($hash, "msgPeer", $mpeer);				
        readingsBulkUpdate($hash, "msgText", $mtext);				

        readingsEndUpdate($hash, 1);

      } elsif ( $msg =~ /^(-?\d+)\s\[[^\]]+\]\s+!_([^»]*)\s\»»»\s(.*)$/s  ) {
        # secret chats have slightly different message format: can have a minus / !_ prefix on name and underscore between first and last / Â» instead of >
        my $mid = $1;
        my $mpeer = $2;
        my $mtext = $3;
        Log3 $name, 5, "Telegram_Read $name: Found secret message $mid from $mpeer :$mtext:";
   
        readingsBeginUpdate($hash);

        readingsBulkUpdate($hash, "prevMsgId", $hash->{READINGS}{msgId}{VAL});				
        readingsBulkUpdate($hash, "prevMsgPeer", $hash->{READINGS}{msgPeer}{VAL});				
        readingsBulkUpdate($hash, "prevMsgText", $hash->{READINGS}{msgText}{VAL});				

        readingsBulkUpdate($hash, "msgId", "secret");				
        readingsBulkUpdate($hash, "msgPeer", $mpeer);				
        readingsBulkUpdate($hash, "msgText", $mtext);				

        readingsEndUpdate($hash, 1);

      }

    }

  }
  
}

#####################################
# Initialize a connection to the telegram-cli
# requires to ensure commands are accepted / set this as main_session, get last msg id 
sub Telegram_Write($$) {
  my ($hash,$msg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Write $name: called ";

  return Telegram_DoCommand( $hash, $msg, undef );  

} 




##############################################################################
##############################################################################
##
## HELPER
##
##############################################################################
##############################################################################

#####################################
# Initialize a connection to the telegram-cli
# requires to ensure commands are accepted / set this as main_session, get last msg id 
sub Telegram_DoInit($)
{
	my ( $hash ) = @_;
  my $name = $hash->{NAME};

	my $buf = '';
	
  Log3 $name, 5, "Telegram_DoInit $name: called ";

  # First needs send an empty line and read all returns away
  $buf = Telegram_DoCommand( $hash, '', undef );
  Log3 $name, 5, "Telegram_DoInit $name: Inital response is :".(defined($buf)?$buf:"undef").": ";

  # Send "main_session" ==> returns empty
  $buf = Telegram_DoCommand( $hash, 'main_session', '' );
  Log3 $name, 5, "Telegram_DoInit $name: Response on main_session is :".(defined($buf)?$buf:"undef").": ";
  return "DoInit failed on main_session with return :".(defined($buf)?$buf:"undef").":" if ( defined($buf) && ( length($buf) > 0 ));
  
  #	- handle initialization (client write / main session / read msg id and checks) in DoInit
  $hash->{STATE} = "Initialized" if(!$hash->{STATE});

  # ??? last message id and read all missing messages for default peer
  
  $hash->{STATE} = "Ready" if(!$hash->{STATE});
  
  return undef;
}

#####################################
# INTERNAL: Function to send a message to a peer and handle result
sub Telegram_SendMessage($$$)
{
	my ( $hash, $peer, $msg ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "Telegram_SendMessage $name: called ";

  # trim and convert spaces in peer to underline 
  my $peer2 = $peer;
     $peer2 =~ s/^\s+|\s+$//g;
     $peer2 =~ s/ /_/g;
    
  
  $hash->{sentMsgText} = $msg;
  $hash->{sentMsgPeer} = $peer2;

  my $defSec = AttrVal($name,'defaultSecret',0);
  if ( $defSec ) {
    $peer2 = "!_".$peer2;
    $hash->{sentMsgSecure} = "secure";
  } else {
    $hash->{sentMsgSecure} = "normal";
  }

  my $cmd = "msg $peer2 $msg";
  my $ret = Telegram_DoCommand( $hash, $cmd, "SUCCESS" );
  if ( defined($ret) ) {
    $hash->{sentMsgResult} = $ret;
  } else {
    $hash->{sentMsgResult} = "SUCCESS";
  }

  return $ret;
}


#####################################
# INTERNAL: Function to get a message by id
sub Telegram_GetMessage($$)
{
	my ( $hash, $msgid ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "Telegram_GetMessage $name: called ";
    
  my $cmd = "get_message $msgid";
  
  return Telegram_DoCommand( $hash, $cmd, undef );
}


#####################################
# INTERNAL: Function to send a command handle result
# Parameter
#   hash
#   cmd - command line to be executed
#   expect - 
#        undef - means no parsing of result - Everything is returned
#        true - parse for SUCCESS = undef / FAIL: = msg
#        false - expect nothing - so return undef if nothing got / FAIL: = return this
sub Telegram_DoCommand($$$)
{
	my ( $hash, $cmd, $expect ) = @_;
  my $name = $hash->{NAME};
	my $buf = '';
  
  Log3 $name, 5, "Telegram_DoCommand $name: called ";

  Log3 $name, 5, "Telegram_DoCommand $name: send command :$cmd: ";
  
  # Check for message in outstanding data from device
  $hash->{REMAINING} = '' if( ! defined($hash->{REMAINING}) );

  $buf = DevIo_SimpleReadWithTimeout($hash, 0.01);
  if ( $buf ) {
    Log3 $name, 5, "Telegram_DoCommand $name: Remaining read :$buf: ";
    $hash->{REMAINING} = $hash->{REMAINING}.$buf;
  }
  
  # Now write the message
  DevIo_SimpleWrite($hash, $cmd."\n", 0);

  Log3 $name, 5, "Telegram_DoCommand $name: send command DONE ";

  $buf = DevIo_SimpleReadWithTimeout($hash, 0.1);
  Log3 $name, 5, "Telegram_DoCommand $name: returned :".(defined($buf)?$buf:"undef").": ";
  
  ### Attention this might contain multiple messages - so split into separate messages and just check for failure or success

  # Return complete buffer if nothing expected
  return $buf if ( ! defined( $expect ) );

  my ( $msg, $rawMsg );

  # Parse the different messages in the buffer
  while ( length($buf) > 0 ) {
    ( $msg, $rawMsg, $buf ) = Telegram_getNextMessage( $hash, $buf );
    Log3 $name, 5, "Telegram_DoCommand $name: parsed a message :".$msg.": ";
    Log3 $name, 5, "Telegram_DoCommand $name: and rawMsg :".$rawMsg.": ";
    Log3 $name, 5, "Telegram_DoCommand $name: and remaining :".$buf.": ";
    if ( length($msg) > 0 ) {
      # Only FAIL / SUCCESS will be handled
      if ( $msg =~ /^FAIL:/ ) {
        $hash->{REMAINING} = $hash->{REMAINING}.$buf;
        return $msg;
      } elsif ( $msg =~ /^SUCCESS$/s ) {
        $hash->{REMAINING} = $hash->{REMAINING}.$buf;
        return undef;
      } else {
        $hash->{REMAINING} = $hash->{REMAINING}.$rawMsg;
      }
    } else {
      $hash->{REMAINING} = $hash->{REMAINING}.$buf;
      return $rawMsg;
    }
  }

  # All messages handled no Failure or success received
  if ( $expect ) {
    return "NO RESULT";
  }
  
  return undef;
}

#####################################
# INTERNAL: Function to split buffer into separate messages
# Parameter
#   hash
#   buf
# RETURNS
#   msg - parsed message without ANSWER
#   rawMsg - raw message 
#   buf - remaining buffer after removing (raw)msg
sub Telegram_getNextMessage($$)
{
	my ( $hash, $buf ) = @_;
  my $name = $hash->{NAME};

  if ( $buf =~ /^(ANSWER\s(\d+)\n)(.*)$/s ) {
    # buffer starts with message
      my $headMsg = $1;
      my $count = $2;
      my $rembuf = $3;
    
      # not enough characters in buffer / should not happen
      return ( '', $rembuf, '' ) if ( length($rembuf) < $count );

      my $msg = substr $rembuf, 0, $count-1; 
      $rembuf = substr $rembuf, $count+1;
      
      return ( $msg, $headMsg.$msg."\n", $rembuf );
  
  }  elsif ( $buf =~ /^([Â]+)(ANSWER\s(\d+)\n(.*\n))$/s ) {
    # There seems to be some other message coming
    return ( '', $1, $2 );
  }

  # No message found consider this all as raw
  return ( '', $buf, '' );
}


##############################################################################
##############################################################################
##
## Documentation
##
##############################################################################
##############################################################################

1;

=pod
=begin html

<a name="Telegram"></a>
<h3>Telegram</h3>
<ul>
  The Telegram module allows the usage of the instant messaging service <a href="https://telegram.org/">Telegram</a> from FHEM in both directions (sending and receiving). 
  So FHEM can use telegram for notifications of states or alerts, general informations and actions can be triggered.
  <br>
  <br>
  Precondition is the installation of the telegram-cli (for unix) see here <a href="https://github.com/vysheng/tg">https://github.com/vysheng/tg</a>
  telegram-cli needs to be configured and registered for usage with telegram. Best is the usage of a dedicated phone number for telegram, 
  so that messages can be sent to and from a dedicated account and read status of messages can be managed. 
  telegram-cli needs to run as a daemon listening on a tcp port to enable communication with FHEM. 
  <br><br>
  <code>
    telegram-cli -k &lt;path to key file e.g. tg-server.pub&gt; -W -C -d -P &lt;portnumber&gt; [--accept-any-tcp] -L &lt;logfile&gt; -l 20 -N -R &
  </code>
  <br><br>
  <dl> 
    <dt>-C</dt>
    <dd>REQUIRED: disable color output to avoid terminal color escape sequences in responses. Otherwise parser will fail on these</dd>
    <dt>-d</dt>
    <dd>REQUIRED: running telegram-cli as daemon (background process decoupled from terminal)</dd>
    <dt>-k &lt;path to key file e.g. tg-server.pub&gt</dt>
    <dd>Path to the keyfile for telegram-cli, usually something like <code>tg-server.pub</code></dd>
    <dt>-L &lt;logfile&gt;</dt>
    <dd>Specify the path to the logfile for telegram-cli. This is especially helpful for debugging purposes and 
      used in conjunction with the specifed log level e.g. (<code>-l 20</code>)</dd>
    <dt>-l &lt;loglevel&gt;</dt>
    <dd>numeric log level for output in log file</dd>
    <dt>-N</dt>
    <dd>REQUIRED: to be able to deal with msgIds</dd>
    <dt>-P &lt;portnumber&gt;</dt>
    <dd>REQUIRED: Port number on which the daemon should be listening e.g. 12345</dd>
    <dt>-R</dt>
    <dd>Readline disable to avoid logfile being filled with edit sequences</dd>
    <dt>-v</dt>
    <dd>More verbose output messages</dd>
    <dt>-W</dt>
    <dd>REQUIRED?: seems necessary to ensure communication with telegram server is correctly established</dd>

    <dt>--accept-any-tcp</dt>
    <dd>Allows the access to the daemon also from distant machines. This is only needed of the telegram-cli is not running on the same host than fhem.
      <br>
      ATTENTION: There is normally NO additional security requirement to access telegram-cli, so use this with care!</dd>
  </dl>
  <br><br>
  More details to the command line parameters of telegram-cli can be found here: <a href="https://github.com/vysheng/tg/wiki/Telegram-CLI-Arguments>Telegram CLI Arguments</a>
  <br><br>
  In my environment, I could not run telegram-cli as part of normal raspbian startup as a daemon as described here:
   <a href="https://github.com/vysheng/tg/wiki/Running-Telegram-CLI-as-Daemon">Running Telegram CLI as Daemon</a> but rather start it currently manually as a background daemon process.
  <code>
    telegram-cli -k tg-server.pub -W -C -d -P 12345 --accept-any-tcp -L telegram.log -l 20 -N -R -vvv &
  </code>
  <br><br>
  The Telegram module allows receiving of (text) messages to any peer (telegram user) and sends text messages to the default peer specified as attribute.
  <br>
  <br><br>
  <a name="Telegramlimitations"></a>
  <br>
  <b>Limitations and possible extensions</b>
  <ul>
    <li>Message id handling is currently not yet implemented<br>This specifically means that messages received 
    during downtime of telegram-cli and / or fhem are not handled when fhem and telegram-cli are getting online again.</li> 
    <li>Running telegram-cli as a daemon with unix sockets is currently not supported</li> 
  </ul>

  <br><br>
  <a name="Telegramdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Telegram  [&lt;hostname&gt;:]&lt;port&gt; </code>
    <br><br>
    Defines a Telegram device either running locally on the fhem server host by specifying only a port number or remotely on a different host by specifying host and portnumber separated by a colon.
    
    Examples:
    <ul>
      <code>define user1 Telegram 12345</code><br>
      <code>define admin Telegram myserver:22222</code><br>
    </ul>
    <br>
  </ul>
  <br><br>

  <a name="Telegramset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; is one of
    <br><br>
    <li>message &lt;text&gt;<br>Sends the given message to the currently defined default peer user</li>
    <li>messageTo &lt;peer&gt; &lt;text&gt;<br>Sends the given message to the given peer. 
    Peer needs to be given without space or other separator, i.e. spaces should be replaced by underscore (e.g. first_last)</li>
    <li>raw &lt;raw command&gt;<br>Sends the given ^raw command to the client</li>
  </ul>
  <br><br>

  <a name="Telegramget"></a>
  <b>Get</b>
  <ul>
    <code>get &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; is one of
    <br><br>
    <li>msgById &lt;message id&gt;<br>Retrieves the message identifed by the corresponding message id</li>
  </ul>
  <br><br>

  <a name="Telegramattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    <li>defaultPeer &lt;name&gt;<br>Specify first name last name of the default peer to be used for sending messages. The peer should and can be given in the form of a firstname_lastname. 
    For scret communication will be the !_ automatically put as a prefix.</li> 
    <li>defaultSecret<br>Use secret chat for communication with defaultPeer. 
    LIMITATION: If no secret chat has been started with the corresponding peer, message send might fail. (see set secretChat)
    </li> 
    <li>lastMsgId &lt;number&gt;<br>Specify the last message handled by Telegram.<br>NOTE: Not yet handled</li> 
    <li><a href="#verbose">verbose</a></li>
  </ul>
  <br><br>
  
  <a name="Telegramreadings"></a>
  <b>Readings</b>
  <br><br>
  <ul>
    <li>msgId &lt;text&gt;<br>The id of the last received message is stored in this reading. 
    For secret chats a value of -1 will be given, since the msgIds of secret messages are not part of the consecutive numbering</li> 
    <li>msgPeer &lt;text&gt;<br>The sender of the last received message.</li> 
    <li>msgText &lt;text&gt;<br>The last received message text is stored in this reading.</li> 

    <li>prevMsgId &lt;text&gt;<br>The id of the SECOND last received message is stored in this reading.</li> 
    <li>prevMsgPeer &lt;text&gt;<br>The sender of the SECOND last received message.</li> 
    <li>prevMsgText &lt;text&gt;<br>The SECOND last received message text is stored in this reading.</li> 
  </ul>
  <br><br>
  
</ul>

=end html
=cut
