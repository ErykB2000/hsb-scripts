program blackknightio;
{
 Make I/O on a shift register (74LS673) coupled to an input multiplexer (74150)
 using a raspberry pi and only 4 GPIO lines

 (c) 2013 Frederic Pasteleurs <frederic@askarel.be>

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program or from the site that you downloaded it
 from; if not, see <http://www.gnu.org/licenses/>.

 The PiGPIO library included in this repository is (c) 2013 Gábor Szöllösi
}

// This is a quick hack to check if everything works

uses PiGpio, sysutils, crt, keyboard, strutils, baseunix, ipc, systemlog, pidfile, unix;

CONST   SHITBITS=63;

TYPE    TDbgArray= ARRAY [0..15] OF string[15];
        TRegisterbits=bitpacked array [0..15] of boolean; // Like a word: a 16 bits bitfield
        TLotsofbits=bitpacked array [0..SHITBITS] of boolean; // A shitload of bits to abuse. 64 bits should be enough. :-)
        TSHMVariables=RECORD // What items should be exposed for IPC.
                Inputs, outputs, fakeinputs: TRegisterbits;
                state, Config :TLotsofbits;
                senderpid: TPid;
                Command: byte;
                SHMMsg:string;
                end;
        TBusyBuzzerScratch=RECORD
                TimeIndex: longint;
                offset: longint;
                end;
        TBuzzPattern= ARRAY [0..20] OF LONGINT;
        TConfigTextArray=ARRAY [0..SHITBITS] of string[20];

CONST   CLOCKPIN=7;  // 74LS673 pins
        STROBEPIN=8;
        DATAPIN=25;
        READOUTPIN=4; // Output of 74150
        MAXBOUNCES=8;

        // Possible commands and their names
        CMD_NONE=0; CMD_OPEN=1; CMD_TUESDAY=2; CMD_ENABLE=3; CMD_DISABLE=4; CMD_BEEP=5; CMD_STOP=6;
        CMD_NAME: ARRAY [CMD_NONE..CMD_STOP] of pchar=('NoCMD','open','tuesday','enable','disable','beep','stop');

        bits:array [false..true] of char=('0', '1');
        // Hardware bug: i got the address lines reversed while building the board.
        // Using a lookup table to mirror the address bits
        BITMIRROR: array[0..15] of byte=(0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15);
        // Various timers, in milliseconds (won't be accurate at all, but time is not critical)
        COPENWAIT=4000; // How long to leave the door unlocked after receiving open order
        LOCKWAIT=2000;  // Maximum delay between leaf switch closure and maglock feedback switch closure (if delay expired, alert that the door is not closed properly
        MAGWAIT=1500;   // Reaction delay of the maglock output relay (the PCB has capacitors)
        BUZZERCHIRP=150; // Small beep delay
        SND_MISTERCASH: TBuzzPattern=(150, 50, 150, 50, 150, 50, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        // Places to look for the external script
        SCRIPTNAMES: array [0..5] of string=('/etc/blackknightio/blackknightio.sh',
                                             '/usr/local/etc/blackknightio/blackknightio.sh',
                                             '/usr/local/etc/blackknightio.sh',
                                             '/usr/local/bin/blackknightio.sh',
                                             '/usr/bin/blackknightio.sh',
                                             '/root/blackknightio.sh');

        // Available outputs on 74LS673. Outputs Q0 to Q3 are connected to the address inputs of the 74150
        Q15=0; Q14=1; Q13=2; Q12=3; Q11=4; Q10=5; Q9=6; Q8=7; Q7=8; Q6=9; Q5=10; Q4=11;
        // Use more meaningful descriptions of the outputs in the code
        // Outputs Q12, Q13, Q14 and Q15 are not used for the moment. Status LED maybe ?
        BUZZER_OUTPUT=Q4;
        BATTERY_RELAY=Q7;
        MAGLOCK1_RELAY=Q9;
        MAGLOCK2_RELAY=Q8;
        DOOR_STRIKE_RELAY=Q10;
        LIGHT_CONTROL_RELAY=Q6;
        DOORBELL_INHIBIT_RELAY=Q5;
        REDLED=Q14;
        GREENLED=Q15;
        // Available inputs from the 74150
        I15=15; I14=14; I13=13; I12=12; I11=11; I10=10; I9=9; I8=8; I7=7; I6=6; I5=5; I4=4; I3=3; I2=2; I1=1; I0=0;
        // Use more meaningful descriptions of the inputs in the code
        // Inputs OPTO4, IN2 and IN1 are not used for the moment.
        // The numbers below correspond to the numbers printed on the screw terminals
        IN11=I0; IN10=I1; IN9=I2; IN8=I3; IN7=I4; IN6=I5; IN5=I6; IN4=I7; IN3=I8; IN2=I9; IN1=I10; OPTO1=I12; OPTO2=I13; OPTO3=I14; OPTO4=I15;
        PANIC_SENSE=I11;
        DOORBELL1=OPTO1;
        DOORBELL2=OPTO2;
        DOORBELL3=OPTO3;
        BOX_TAMPER_SWITCH=IN11;
        MAGLOCK1_RETURN=IN10;
        MAGLOCK2_RETURN=IN9;
        LIGHTS_ON_SENSE=IN6;
        DOOR_CLOSED_SWITCH=IN5;
        DOORHANDLE=IN4;
        MAILBOX=IN3;     // Of course we'll have physical mail notification. :-)
        TRIPWIRE_LOOP=IN2;
        DOOR_OPEN_BUTTON=IN1;
        IS_CLOSED=false;
        IS_OPEN=true;
//        DBGINSTATESTR: Array [IS_CLOSED..IS_OPEN] of string[5]=('closed', 'open');
//        DBGOUTSTATESTR: Array [false..true] of string[5]=('On', 'Off');
        CFGSTATESTR: Array [false..true] of string[8]=('Disabled','Enabled');
        DBGOUT: TDbgArray=('Green LED', 'Red LED', 'Q13 not used', 'Q12 not used', 'relay not used', 'strike', 'mag1 power', 'mag2 power', 'not used',
                                'light', 'bell inhib.', 'Buzzer', '74150 A3', '74150 A2', '74150 A1', '74150 A0');
        DBGIN: TDbgArray=('TAMPER BOX','MAG1 CLOSED','MAG2 CLOSED','IN 8','IN 7','Light on sense','door closed','Handle',
                          'Mailbox','Tripwire','opendoorbtn','PANIC SWITCH','DOORBELL 1','DOORBELL 2','DOORBELL 3','OPTO 4');
        // offsets in status/config bitfields
        SC_MAGLOCK1=0; SC_MAGLOCK2=1; SC_TRIPWIRE_LOOP=2; SC_BOX_TAMPER_SWITCH=3; SC_MAILBOX=4; SC_BUZZER=5; SC_BATTERY=6; SC_HALLWAY=7;
        SC_DOORSWITCH=8; SC_HANDLEANDLIGHT=9; SC_DOORUNLOCKBUTTON=10; SC_HANDLE=11; SC_DISABLED=12;
        // Status bit block only
        S_DEMOMODE=63; S_TUESDAY=62; S_STOP=61; S_HUP=60;

        // Static config
        STATIC_CONFIG_STR: TConfigTextArray=('Maglock 1',
                                             'Maglock 2',
                                             'Tripwire loop',
                                             'Box tamper',
                                             'Mail notification',
                                             'buzzer',
                                             'Backup Battery',
                                             'Hallway lights',
                                             'Door leaf switch',
                                             'handle+light unlock',
                                             'Door unlock button',
                                             'Handle unlock only',
                                             'Software-disabled',
                                             '', '',  '', '', '', '', '', '', '', '', '', '', '',
                                             '', '', '', '', '', '', '', '', '',  '', '', '', '', '', '', '', '', '', '',
                                             '', '', '', '', '', '', '', '', '',  '', '', '', '', '', '', 'HUP received', 'Stop order', 'Tuesday mode', 'Demo mode');

        STATIC_CONFIG: TLotsOfBits=(false,  // SC_MAGLOCK1 (Maglock 1 installed)
                                    true, // SC_MAGLOCK2 (Maglock 2 not installed)
                                    false,  // SC_TRIPWIRE_LOOP (Tripwire not installed)
                                    false,  // SC_BOX_TAMPER_SWITCH (Tamper switch installed)
                                    true,  // SC_MAILBOX (Mail detection installed)
                                    true,  // SC_BUZZER (Let it make some noise)
                                    false, // SC_BATTERY (battery not attached)
                                    false, // SC_HALLWAY (Hallway light not connected)
                                    true,  // SC_DOORSWITCH (Door leaf switch installed)
                                    true,  // SC_HANDLEANDLIGHT (The light must be on to unlock with the handle)
                                    true,  // SC_DOORUNLOCKBUTTON (A push button to open the door)
                                    false, // SC_HANDLE (Unlock with the handle only: not recommended in HSBXL)
                                    true, // SC_DISABLED (system is software-disabled)
                                    false,
                                    false, false, false, false, false, false, false, false, false, false, false, false, false,
                                    false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
                                    false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
                                    false,
                                    false, // Unused
                                    false, // Unused
                                    false, // Unused
                                    false  // Unused
                                    );

VAR     GPIO_Driver: TIODriver;
        GpF: TIOPort;
        debounceinput_array: ARRAY[false..true, 0..15] of byte; // That one has to be global. No way around it.
        CurrentState,   // Reason for global: it is modified by the signal handler
        msgflags: TLotsOfBits; // Reason for global: message state must be preserved (avoid spamming the syslog)
        BuzzerTracker: TBusyBuzzerScratch;

///////////// COMMON LIBRARY FUNCTIONS /////////////

// Return gray-encoded input
function graycode (inp: longint): longint;
begin
 graycode:=(inp shr 1) xor inp;
end;

function word2bits (inputword: word): TRegisterbits;
begin
 word2bits:=TRegisterbits (inputword); // TRegisterbits is a word-sized array of bits
end;

function bits2word (inputbits: TRegisterbits): word;
begin
 bits2word:=word (inputbits);
end;

function bits2str (inputbits: TRegisterbits): string;
var i: byte;
    s: string;
begin
 s:='';
 for i:=(bitsizeof (TRegisterbits)-1) downto 0 do s:=s+bits[inputbits[i]];
 bits2str:=s;
end;

// TODO: glitch counter
function debounceinput (inputbits: TRegisterbits; samplesize: byte): TRegisterbits;
var i: byte;
begin
 for i:=0 to 15 do
  begin
//  delay (10);
   debounceinput_array[inputbits[i]][i]:= debounceinput_array[inputbits[i]][i] + 1; // increment counters
//   writeln ('input[0] state: ', inputbits[0], '  debounce 0[0]: ', debounceinput_array[false][0], '  debounce 1[0]', debounceinput_array[true][0], '    ');
   if debounceinput_array[false][i] >= samplesize then
    begin
     debounceinput_array[true][i]:=0; // We have a real false, resetting counters
     debounceinput_array[false][i]:=0;
     debounceinput[i]:=false;
    end;
   if debounceinput_array[true][i] >= samplesize then
    begin
     debounceinput_array[true][i]:=0; // we have a real true, resetting counters
     debounceinput_array[false][i]:=0;
     debounceinput[i]:=true;
    end;
  end;
end;

// Apparently, despite the crappy CPU on the raspberry pi, it is too fast for the shift register.
// This should help the shift register to settle
procedure wastecpucycles (waste: word);
var i: word;
begin
 for i:=0 to waste do
  asm
   nop // How handy... This is portable ASM... :-)
  end;
end;

// Decrement the timer variable
procedure busy_delay_tick (var waitvar: longint; ticklength: word);
var mytick: word;
begin
 if ticklength <= 0 then mytick:=1 else mytick:=ticklength;
 if waitvar >= 0 then waitvar:=waitvar - ticklength else waitvar:=0;
end;

// Is the timer expired ?
function busy_delay_is_expired (var waitvar: longint): boolean;
begin
 if waitvar <= 0 then busy_delay_is_expired:=true
                 else busy_delay_is_expired:=false;
end;

// Play a beep pattern
function busy_buzzer (var scratchspace: TBusyBuzzerScratch; pattern: TBuzzpattern; ticklength: word): boolean;
begin
 if (pattern[scratchspace.offset] = 0) then busy_buzzer:=false // End of pattern: shut up.
  else
  begin
   if (scratchspace.TimeIndex <= 0) then scratchspace.TimeIndex:=pattern[scratchspace.offset];
   busy_buzzer:=((scratchspace.offset and 1) = 0);// Beep !!
   busy_delay_tick (scratchspace.TimeIndex, ticklength);
   if busy_delay_is_expired (scratchspace.TimeIndex) then
    begin
     inc (scratchspace.offset); // Next !!
     scratchspace.TimeIndex:=pattern[scratchspace.offset];
    end;
  end
end;

// Log an event and run external script
procedure log_door_event (var currentstateflags: TLotsOfBits; msgindex: byte; currentbitstate: boolean; msgtext, extratext: pchar);
var pid: Tpid;
begin
 if currentstateflags[msgindex] <> currentbitstate then
  begin
   if currentbitstate then
    begin
     syslog (log_warning, 'message %d: %s (%s)', [msgindex, msgtext, extratext]);
     pid:=fpFork;
     if pid = 0 then
      begin
      fpexecl (paramstr (0) + '.sh', [inttostr (msgindex), msgtext, extratext] );
      syslog (LOG_WARNING, 'Process returned: error code: %d', [FpGetErrNo]);
      halt(0);
      end;
    end;
   currentstateflags[msgindex]:=currentbitstate;
  end;
end;

procedure dump_config (bits: TLotsofbits; textdetail:TConfigTextArray );
var i: byte;
begin
 for i:=0 to SHITBITS do if textdetail[i] <> '' then writeln ('Config option ', i, ': ', textdetail[i], ': ', CFGSTATESTR[bits[i]]);
end;

///////////// DEBUG FUNCTIONS /////////////

// Decompose a word into bitfields with description
procedure debug_showbits (inputbits, oldbits: TRegisterbits; screenshift: byte; description: TDbgArray );
const modchar: array [false..true] of char=(' ', '>');
var i, oldx, oldy: byte;
begin
 if bits2word (inputbits) <> bits2word (oldbits) then
 begin
  oldx:=wherex; oldy:=wherey;
  for i:=0 to 15 do
   begin
    description[i][0]:=char (15);// Trim length
    gotoxy (1 + screenshift, i + 2); write ( bits[inputbits[i]], modchar[(inputbits[i]<>oldbits[i])], description[i]);
   end;
   gotoxy (oldx, oldy);
 end;
//  writeln;
end;

// This run as another process and will monitor the SHM buffer for changes.
// If in demo mode, you will be able to fiddle the inputs
procedure run_test_mode (daemonpid: TPid);
var  shmid: longint;
     shmkey: TKey;
     SHMPointer: ^TSHMVariables;
     oldin, oldout: TRegisterbits;
     shmname, key: string;
     K: TKeyEvent;
     quitcmd: boolean;
     i: byte;
begin
 if daemonpid = 0 then
  begin
   writeln ('Daemon not started.');
   halt (1);
  end
 else
  begin
   shmname:=paramstr (0) + #0;
   shmkey:=ftok (pchar (@shmname[1]), daemonpid);
   shmid:=shmget (shmkey, sizeof (TSHMVariables), 0);
   // Add test for shmget error here ?
   SHMPointer:=shmat (shmid, nil, 0);
   SHMPointer^.senderpid:=FpGetPid;
   oldin:=word2bits (0);
   oldout:=word2bits (1);
   quitcmd:=false;
   initkeyboard;
   clrscr;
   writeln ('Black Knight Monitor -- keys: k kill system - n enable/disable - o open door - q quit Monitor - r refresh');
   gotoxy (1,18);
   while not ( SHMPointer^.state[S_STOP] or quitcmd ) do
    begin
     K:=PollKeyEvent; // Check for keyboard input
     if k<>0 then // Key pressed ?
      begin
       k:=TranslateKeyEvent (GetKeyEvent);
       key:= KeyEventToString (k);
       case key of
        '0': if SHMPointer^.inputs[0] then SHMPointer^.fakeinputs[0]:=false else SHMPointer^.fakeinputs[0]:=true;
        '1': if SHMPointer^.inputs[1] then SHMPointer^.fakeinputs[1]:=false else SHMPointer^.fakeinputs[1]:=true;
        '2': if SHMPointer^.inputs[2] then SHMPointer^.fakeinputs[2]:=false else SHMPointer^.fakeinputs[2]:=true;
        '3': if SHMPointer^.inputs[3] then SHMPointer^.fakeinputs[3]:=false else SHMPointer^.fakeinputs[3]:=true;
        '4': if SHMPointer^.inputs[4] then SHMPointer^.fakeinputs[4]:=false else SHMPointer^.fakeinputs[4]:=true;
        '5': if SHMPointer^.inputs[5] then SHMPointer^.fakeinputs[5]:=false else SHMPointer^.fakeinputs[5]:=true;
        '6': if SHMPointer^.inputs[6] then SHMPointer^.fakeinputs[6]:=false else SHMPointer^.fakeinputs[6]:=true;
        '7': if SHMPointer^.inputs[7] then SHMPointer^.fakeinputs[7]:=false else SHMPointer^.fakeinputs[7]:=true;
        '8': if SHMPointer^.inputs[8] then SHMPointer^.fakeinputs[8]:=false else SHMPointer^.fakeinputs[8]:=true;
        '9': if SHMPointer^.inputs[9] then SHMPointer^.fakeinputs[9]:=false else SHMPointer^.fakeinputs[9]:=true;
        'a': if SHMPointer^.inputs[10] then SHMPointer^.fakeinputs[10]:=false else SHMPointer^.fakeinputs[10]:=true;
        'b': if SHMPointer^.inputs[11] then SHMPointer^.fakeinputs[11]:=false else SHMPointer^.fakeinputs[11]:=true;
        'c': if SHMPointer^.inputs[12] then SHMPointer^.fakeinputs[12]:=false else SHMPointer^.fakeinputs[12]:=true;
        'd': if SHMPointer^.inputs[13] then SHMPointer^.fakeinputs[13]:=false else SHMPointer^.fakeinputs[13]:=true;
        'e': if SHMPointer^.inputs[14] then SHMPointer^.fakeinputs[14]:=false else SHMPointer^.fakeinputs[14]:=true;
        'f': if SHMPointer^.inputs[15] then SHMPointer^.fakeinputs[15]:=false else SHMPointer^.fakeinputs[15]:=true;
        'q': quitcmd:=true;
        'k': begin
              SHMPointer^.command:=CMD_STOP;
              SHMPointer^.SHMMSG:='Quit order given by Monitor';
              fpkill (daemonpid, SIGHUP);
             end;
        'n': begin
              if SHMPointer^.State[SC_DISABLED] then
               begin
                SHMPointer^.command:=CMD_ENABLE;
                SHMPointer^.SHMMSG:='Enabled by Monitor';
               end
              else
               begin
                SHMPointer^.command:=CMD_DISABLE;
                SHMPointer^.SHMMSG:='Disabled by Monitor';
               end;
              fpkill (daemonpid, SIGHUP);
             end;
        'o': begin
              SHMPointer^.command:=CMD_OPEN;
              SHMPointer^.SHMMSG:='Open from Monitor';
              fpkill (daemonpid, SIGHUP);
             end;
        'r': begin
              for i:=0 to 15 do
               begin
                oldout[i]:=not SHMPointer^.outputs[i];
                oldin[i]:= not SHMPointer^.inputs[i];
               end;
              writeln ('Forcing refresh');
             end;
        else writeln ('Invalid key: ',key);
       end;
      end;
     // Do some housekeeping
     debug_showbits (SHMPointer^.outputs, oldout, 0, DBGOUT);
     debug_showbits (SHMPointer^.inputs, oldin, 17, DBGIN);
     oldout:=SHMPointer^.outputs;
     oldin:=SHMPointer^.inputs;
     sleep (1);
    end;
   // Cleanup
   if quitcmd then writeln ('Quitting Monitor.')
              else writeln ('Main program stopped. Quitting as well.');
   donekeyboard;
  end;
end;

///////////// CHIP HANDLING FUNCTIONS /////////////

// Send out a word to the 74LS673
procedure write74673 (clockpin, datapin, strobepin: byte; data: TRegisterbits);
var i: byte;
begin
 for i:=0 to 15 do
 begin
  GpF.SetBit (clockpin);
  wastecpucycles (4);
  if data[i] then GpF.SetBit (datapin) else GpF.Clearbit (datapin);
  wastecpucycles (4);
  GpF.ClearBit (clockpin);
  wastecpucycles (4);
 end;
 GpF.SetBit (strobepin);
 wastecpucycles (4);
 GpF.Clearbit (strobepin);
end;

// Do an I/O cycle on the board
function io_673_150 (clockpin, datapin, strobepin, readout: byte; data:TRegisterbits): TRegisterbits;
var i: byte;
    gpioword: word;
begin
 gpioword:=0;
 for i:=0 to 15 do
  begin
   write74673 (clockpin, datapin, strobepin, word2bits ((bits2word (data) and $0fff) or (BITMIRROR[graycode (i)] shl $0c)) );
   sleep (1); // Give the electronics time for propagation
   gpioword:=(gpioword or (ord (GpF.GetBit (readout)) shl graycode(i) ) );
  end;
 io_673_150:=word2bits (gpioword);
end;

// Return true if the GPIO pins have been successfully initialized
function initgpios (clockpin, datapin, strobepin, readout: byte): boolean;
begin
 if GPIO_Driver.MapIo then
  begin
   GpF := GpIo_Driver.CreatePort(GPIO_BASE, CLOCK_BASE, GPIO_PWM);
   GpF.SetPinMode (clockpin, pigpio.OUTPUT);
   GpF.setpinmode (strobepin, pigpio.OUTPUT);
   GpF.setpinmode (datapin, pigpio.OUTPUT);
   GpF.setpinmode (readout, pigpio.INPUT);
   initgpios:=true;
  end
  else
   initgpios:=false;
end;

///////////// RUN THE FUCKING DOOR /////////////
///////////// DAEMON STUFF /////////////

procedure godaemon (daemonpid: Tpid);
var shmname: string;
    inputs, outputs : TRegisterbits;
    shmkey: TKey;
    shmid: longint;
    SHMPointer: ^TSHMVariables;
    dryrun: byte;
    open_wait, beepdelay, Mag1CloseWait, Mag2CloseWait, Mag1LockWait, Mag2LockWait: longint;
    sys_open_order, door_is_locked: boolean;
begin
 outputs:=word2bits (0);
 dryrun:=MAXBOUNCES+2;
 open_wait:=0; beepdelay:=0; Mag1CloseWait:=MAGWAIT; Mag2CloseWait:=MAGWAIT; Mag1LockWait:=LOCKWAIT; Mag2LockWait:=LOCKWAIT; // Initialize some timers
 door_is_locked:=false;
 fillchar (CurrentState, sizeof (CurrentState), 0);
 fillchar (msgflags, sizeof (msgflags), 0);
 fillchar (debounceinput_array, sizeof (debounceinput_array), 0);
 fillchar (buzzertracker, sizeof (buzzertracker), 0);
 CurrentState[SC_DISABLED]:=STATIC_CONFIG[SC_DISABLED]; // Get default state from config
 shmname:=paramstr (0) + #0;
 shmkey:=ftok (pchar (@shmname[1]), daemonpid);
 shmid:=shmget (shmkey, sizeof (TSHMVariables), IPC_CREAT or IPC_EXCL or 438);
 if shmid = -1 then syslog (log_err, 'Can''t create shared memory segment (pid %d). Leaving.', [daemonpid])
 else
  begin // start from a clean state
   SHMPointer:=shmat (shmid, nil, 0);
   fillchar (SHMPointer^, sizeof (TSHMVariables), 0);
   SHMPointer^.fakeinputs:=word2bits (65535);
   if initgpios (CLOCKPIN, STROBEPIN, DATAPIN, READOUTPIN) then
    CurrentState[S_DEMOMODE]:=false
   else
    begin
     syslog (log_warning,'WARNING: Error mapping registry: GPIO code disabled, running in demo mode.', []);
     CurrentState[S_DEMOMODE]:=true;
     inputs:=word2bits (65535); // Open contact = 1
    end;

   repeat
    sys_open_order:=false;
    if CurrentState[S_DEMOMODE] then // I/O cycle
     begin // Fake I/O
      inputs:=debounceinput (SHMPointer^.fakeinputs, MAXBOUNCES);
      sleep (16); // Emulate the real deal
     end
    else // Real I/O
     inputs:=debounceinput (io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, outputs), MAXBOUNCES);
    if CurrentState[S_HUP] then // Process HUP signal
     begin
      SHMPointer^.shmmsg:=SHMPointer^.shmmsg + #0; // Make sure the string is null terminated
      syslog (log_info, 'HUP received from PID %d. Command: "%s" with parameter: "%s"', [ SHMPointer^.senderpid, CMD_NAME[SHMPointer^.command], @SHMPointer^.shmmsg[1]]);
      case SHMPointer^.command of
       CMD_ENABLE: CurrentState[SC_DISABLED]:=false;
       CMD_DISABLE: CurrentState[SC_DISABLED]:=true;
       CMD_STOP: CurrentState[S_STOP]:=true;
       CMD_OPEN: sys_open_order:=true;
       CMD_BEEP: beepdelay:=BUZZERCHIRP; // Small beep
//       CMD_TUESDAY: if CurrentState[S_TUESDAY] then CurrentState[S_TUESDAY]:=false else CurrentState[S_TUESDAY]:=true;
      end;
      SHMPointer^.command:=CMD_NONE;
      CurrentState[S_HUP]:=false; // Reset HUP signal
      SHMPointer^.senderpid:=0; // Reset sender PID: If zero, we may have a race condition
//      fillchar (SHMPointer^.shmmsg, sizeof (SHMPointer^.shmmsg), 0);// Kill the buffer data
     end;

    if dryrun = 0 then // Make a dry run to let inputs settle
     begin
      if CurrentState[SC_DISABLED] then
       begin // System is software-disabled
        outputs:=word2bits (0); // Set all outputs to zero.
        sys_open_order:=false;  // Deny open order (we're disabled)
        open_wait:=0;
        door_is_locked:=false;
       end
      else
       begin // System is enabled. Process outputs
(********************************************************************************************************)
        // Do lock logic shit !!
        if inputs[PANIC_SENSE] = IS_OPEN then
         begin // PANIC MODE (topmost priority)
          outputs[MAGLOCK1_RELAY]:=false;
          outputs[MAGLOCK2_RELAY]:=false;
          sys_open_order:=false;
          door_is_locked:=false;
          open_wait:=0;
         end
        else // no panic
         begin
          if busy_delay_is_expired (open_wait) then
           begin // re-lock
            if STATIC_CONFIG[SC_MAGLOCK1] and (inputs[DOOR_CLOSED_SWITCH] = IS_CLOSED) then outputs[MAGLOCK1_RELAY]:=true;
            if STATIC_CONFIG[SC_MAGLOCK2] and (inputs[DOOR_CLOSED_SWITCH] = IS_CLOSED) then outputs[MAGLOCK2_RELAY]:=true;
//            sys_open_order:=false;
            outputs[DOOR_STRIKE_RELAY]:=false;
            outputs[BUZZER_OUTPUT]:=false;
           end
          else
           begin // Open !!
            busy_delay_tick (open_wait, 16); // tick...
            outputs[MAGLOCK1_RELAY]:=false;
            outputs[MAGLOCK2_RELAY]:=false;
            outputs[DOOR_STRIKE_RELAY]:=true;
            if STATIC_CONFIG[SC_BUZZER] then outputs[BUZZER_OUTPUT]:=true;
            door_is_locked:=false;
           end;
         end;
       end;
(********************************************************************************************************)
      // The maglocks sensing circuit has capacitors. They may still be charged when we turn them off,
      // leaving the return contact closed when we turn the magnet off. Wait a bit before raising an alarm.
      if (inputs[MAGLOCK1_RETURN] = IS_OPEN) then Mag1CloseWait:=MAGWAIT else if not outputs[MAGLOCK1_RELAY] then busy_delay_tick (Mag1CloseWait, 16);
      if (inputs[MAGLOCK2_RETURN] = IS_OPEN) then Mag2CloseWait:=MAGWAIT else if not outputs[MAGLOCK2_RELAY] then busy_delay_tick (Mag2CloseWait, 16);
      // Reset closing timers when magnets are off
      if not outputs[MAGLOCK1_RELAY] then Mag1LockWait:=LOCKWAIT;
      if not outputs[MAGLOCK2_RELAY] then Mag2LockWait:=LOCKWAIT;
      // Start the closing timers when the magnets are on. Stop ticking when the shoe is on the magnet -> door is locked.
      if outputs[MAGLOCK1_RELAY] and (inputs[MAGLOCK1_RETURN] = IS_OPEN) then busy_delay_tick (Mag1LockWait, 16);
      if outputs[MAGLOCK2_RELAY] and (inputs[MAGLOCK2_RETURN] = IS_OPEN) then busy_delay_tick (Mag2LockWait, 16);

      // Do switch monitoring
      if (inputs[PANIC_SENSE] = IS_CLOSED) and (sys_open_order  // Open from system
       or (STATIC_CONFIG[SC_HANDLE] and (inputs[DOORHANDLE] = IS_CLOSED)) // Open from handle only
       or (STATIC_CONFIG[SC_HANDLEANDLIGHT] and (inputs[LIGHTS_ON_SENSE] = IS_CLOSED) and (inputs[DOORHANDLE] = IS_CLOSED)) // Open from handle and light
       or (STATIC_CONFIG[SC_DOORUNLOCKBUTTON] and (inputs[DOOR_OPEN_BUTTON] = IS_CLOSED))// Open from unlock button
       or (CurrentState[S_TUESDAY] and ((inputs[OPTO1] = IS_CLOSED) or (inputs[OPTO2] = IS_CLOSED) or (inputs[OPTO3] = IS_CLOSED)))) // Open from doorbell
        then open_wait:=COPENWAIT; // Start open timer
      if inputs[DOOR_CLOSED_SWITCH] = IS_OPEN then open_wait:=0; // Kill timer if door is open

      if STATIC_CONFIG[SC_MAGLOCK1] and STATIC_CONFIG[SC_MAGLOCK2] then // Two maglocks installed (msg 6-10)
       begin
        log_door_event (msgflags, 6, (busy_delay_is_expired (Mag1LockWait) and (inputs[MAGLOCK2_RETURN] = IS_CLOSED) and outputs[MAGLOCK1_RELAY] and outputs[MAGLOCK2_RELAY]),
         'Partial lock detected: Maglock 1 did not latch.', '');
        log_door_event (msgflags, 7, (busy_delay_is_expired (Mag2LockWait) and (inputs[MAGLOCK1_RETURN] = IS_CLOSED) and outputs[MAGLOCK1_RELAY] and outputs[MAGLOCK2_RELAY]),
         'Partial lock detected: Maglock 2 did not latch.', '');
        log_door_event (msgflags, 8, (busy_delay_is_expired (Mag1LockWait) and busy_delay_is_expired (Mag2LockWait) and outputs[MAGLOCK1_RELAY] and outputs[MAGLOCK2_RELAY]),
         'No maglock latched: Door is not locked.', '');
        if ((inputs[MAGLOCK1_RETURN] = IS_CLOSED) and (inputs[MAGLOCK2_RETURN] = IS_CLOSED) and outputs[MAGLOCK1_RELAY] and outputs[MAGLOCK2_RELAY])
         and (inputs[DOOR_CLOSED_SWITCH] = IS_CLOSED) then door_is_locked:=true;
       end;
      if STATIC_CONFIG[SC_MAGLOCK1] and (not STATIC_CONFIG[SC_MAGLOCK2]) then // Maglock 1 installed alone (msg 11-15)
       begin
        log_door_event (msgflags, 11, (busy_delay_is_expired (Mag1LockWait)),
         'Maglock 1 did not latch: Door is not locked', '');
        if (outputs[MAGLOCK1_RELAY] and (inputs[MAGLOCK1_RETURN] = IS_CLOSED) and (inputs[DOOR_CLOSED_SWITCH] = IS_CLOSED)) then door_is_locked:=true;
       end;
      if (not STATIC_CONFIG[SC_MAGLOCK1]) and STATIC_CONFIG[SC_MAGLOCK2] then // Maglock 2 installed alone (msg 16-20)
       begin
        log_door_event (msgflags, 16, (busy_delay_is_expired (Mag2LockWait)),
         'Maglock 2 did not latch: Door is not locked', '');
        if (outputs[MAGLOCK2_RELAY] and (inputs[MAGLOCK2_RETURN] = IS_CLOSED) and (inputs[DOOR_CLOSED_SWITCH] = IS_CLOSED)) then door_is_locked:=true;
       end;
      if (not STATIC_CONFIG[SC_MAGLOCK1]) and (not STATIC_CONFIG[SC_MAGLOCK2]) then // No maglock installed. Not recommended. (msg 21-25)
       begin
        log_door_event (msgflags, 21, true,  'No magnetic lock installed. This configuration is NOT recommended.', '');
        log_door_event (msgflags, 22, (inputs[DOOR_CLOSED_SWITCH] = IS_CLOSED), 'Door is closed. Cannot see if it is locked', '');
       end;

      { Corner cases to fix:
        - tuesday mode: make it time delayed
      }

      // Process beep commands
      if door_is_locked and STATIC_CONFIG[SC_BUZZER] then
       outputs[BUZZER_OUTPUT]:=(busy_buzzer (buzzertracker, SND_MISTERCASH, 16) or outputs[BUZZER_OUTPUT])
       else fillchar (buzzertracker, sizeof (buzzertracker), 0);
      busy_delay_tick (beepdelay, 16); // tick...
      outputs[BUZZER_OUTPUT]:=(not busy_delay_is_expired (beepdelay)) or outputs[BUZZER_OUTPUT]; // The buzzer might be active elsewhere

      // Process the log/action bits (msg 26-50)
      log_door_event (msgflags, 26, door_is_locked, 'Door is locked.', '');
      log_door_event (msgflags, 27, ((inputs[MAILBOX] = IS_CLOSED) and STATIC_CONFIG[SC_MAILBOX]), 'There is mail in the mailbox', '');
      log_door_event (msgflags, 28, (inputs[PANIC_SENSE] = IS_OPEN), 'PANIC BUTTON PRESSED: MAGNETS ARE DISABLED', '');
      log_door_event (msgflags, 29, ((inputs[TRIPWIRE_LOOP] = IS_OPEN) and STATIC_CONFIG[SC_TRIPWIRE_LOOP]), 'TRIPWIRE LOOP BROKEN: POSSIBLE BREAK-IN', '');
      log_door_event (msgflags, 30, ((inputs[BOX_TAMPER_SWITCH] = IS_OPEN) and STATIC_CONFIG[SC_BOX_TAMPER_SWITCH]), 'Control box is being opened', '');
      log_door_event (msgflags, 31, (busy_delay_is_expired (Mag1CloseWait) and STATIC_CONFIG[SC_MAGLOCK1]),
       'Check maglock 1 and it''s wiring: maglock is off but i see it closed', '');
      log_door_event (msgflags, 32, (busy_delay_is_expired (Mag2CloseWait) and STATIC_CONFIG[SC_MAGLOCK2]),
       'Check maglock 2 and it''s wiring: maglock is off but i see it closed', '');
      log_door_event (msgflags, 33, ((inputs[MAGLOCK1_RETURN] = IS_CLOSED) and not outputs[MAGLOCK1_RELAY] and not STATIC_CONFIG[SC_MAGLOCK1]),
       'Wiring error: maglock 1 is disabled in configuration but i see it closed', '');
      log_door_event (msgflags, 34, ((inputs[MAGLOCK2_RETURN] = IS_CLOSED) and not outputs[MAGLOCK2_RELAY] and not STATIC_CONFIG[SC_MAGLOCK2]),
       'Wiring error: maglock 2 is disabled in configuration but i see it closed', '');
      if msgflags[36] then log_door_event (msgflags, 35, (not CurrentState[S_TUESDAY]), 'Tuesday mode inactive', '');
      log_door_event (msgflags, 36, CurrentState[S_TUESDAY], 'Tuesday mode active. Ring doorbell to enter', '');
      log_door_event (msgflags, 37, ((inputs[LIGHTS_ON_SENSE] = IS_CLOSED) and STATIC_CONFIG[SC_HALLWAY]), 'Hallway light is on', '');
      log_door_event (msgflags, 38, not CurrentState[SC_DISABLED], 'Door System is enabled', '');
      log_door_event (msgflags, 39, CurrentState[SC_DISABLED], 'Door System is disabled in software', '');
      log_door_event (msgflags, 40, ((not CurrentState[SC_DISABLED]) and STATIC_CONFIG[SC_DOORUNLOCKBUTTON] and (inputs[DOOR_OPEN_BUTTON] = IS_CLOSED)),
       'Door opened from button', '');
      log_door_event (msgflags, 41, ((not CurrentState[SC_DISABLED]) and STATIC_CONFIG[SC_HANDLEANDLIGHT] and (not STATIC_CONFIG[SC_HANDLE]) and (inputs[LIGHTS_ON_SENSE] = IS_CLOSED) and (inputs[DOORHANDLE] = IS_CLOSED)),
       'Door opened from handle with the light on', '');
      log_door_event (msgflags, 42, ((not CurrentState[SC_DISABLED]) and STATIC_CONFIG[SC_HANDLE] and (inputs[DOORHANDLE] = IS_CLOSED)), 'Door opened from handle', '');
      log_door_event (msgflags, 43, sys_open_order,  'Order from system', @SHMPointer^.shmmsg[1]);
      log_door_event (msgflags, 44, ((inputs[OPTO1] = IS_CLOSED) or (inputs[OPTO2] = IS_CLOSED) or (inputs[OPTO3] = IS_CLOSED)), 'Ding Ding Dong', '');
      log_door_event (msgflags, 45, (door_is_locked and (inputs [DOOR_CLOSED_SWITCH] = IS_OPEN)),
       'Check wiring of door switch: door is locked but i see it open', '');
      log_door_event (msgflags, 46, (door_is_locked and outputs[MAGLOCK1_RELAY] and (inputs[MAGLOCK1_RETURN] = IS_OPEN) and STATIC_CONFIG[SC_MAGLOCK1]),
       'Magnetic lock 1 or its wiring failed. Please repair.', '');
      log_door_event (msgflags, 47, (door_is_locked and outputs[MAGLOCK2_RELAY] and (inputs[MAGLOCK2_RETURN] = IS_OPEN) and STATIC_CONFIG[SC_MAGLOCK2]),
       'Magnetic lock 2 or its wiring failed. Please repair.', '');
(********************************************************************************************************)
      SHMPointer^.inputs:=inputs;
      SHMPointer^.outputs:=outputs;
      SHMPointer^.state:=CurrentState;
      SHMPointer^.Config:=STATIC_CONFIG;
     end
    else dryrun:=dryrun-1;
   until CurrentState[S_STOP];
  end;
 log_door_event (msgflags, 63, true, 'Door controller is bailing out. Clearing outputs', '');
// syslog (log_crit,'Daemon is exiting. Clearing outputs', []);
 outputs:=word2bits (0);
 if not CurrentState[S_DEMOMODE] then write74673 (CLOCKPIN, DATAPIN, STROBEPIN, outputs);
 sleep (100); // Give time for the monitor to die before yanking the segment
 shmctl (shmid, IPC_RMID, nil); // Destroy shared memory segment upon leaving
end;

// Do something on signal
procedure signalhandler (sig: longint); cdecl;
begin
 case sig of
  SIGHUP: CurrentState[S_HUP]:=true;
  SIGTERM: CurrentState[S_STOP]:=true;
 end;
end;

// Collect and dispose of the dead bodies
procedure children_of_bodom (sig: longint); cdecl;
var childexitcode: cint;
begin
 syslog (log_info, 'Grim reaper: child %d exited with code: %d', [ FpWait (childexitcode), childexitcode]);
end;

// For IPC stuff (sending commands)
Procedure senddaemoncommand (daemonpid: TPid; cmd: byte; comment: string);
var  shmid: longint;
     shmname: string;
     shmkey: tkey;
     SHMPointer: ^TSHMVariables;
begin
 if daemonpid = 0 then
  begin
   writeln ('Daemon not started.');
   halt (1);
  end
 else
  begin
   shmname:=paramstr (0) + #0;
   shmkey:=ftok (pchar (@shmname[1]), daemonpid);
   shmid:=shmget (shmkey, sizeof (TSHMVariables), 0);
   // Add test for shmget error here ?
   SHMPointer:=shmat (shmid, nil, 0);
   writeln (paramstr (0),': Sending command ', CMD_NAME[cmd], ' to PID ', daemonpid);
   SHMPointer^.senderpid:=FpGetPid;
   SHMPointer^.command:=cmd;
   if comment = '' then SHMPointer^.SHMMsg:='<no message provided>'
                   else SHMPointer^.SHMMsg:=comment;
   fpkill (daemonpid, SIGHUP);
  end;
end;


///////////// MAIN BLOCK /////////////
var     shmname, pidname :string;
        aOld, aTerm, aHup, aChild : pSigActionRec;
        zerosigs : sigset_t;
        ps1 : psigset;
        sSet : cardinal;
        oldpid, sid, pid: TPid;
        shmoldkey: TKey;
        shmid: longint;
        iamrunning: boolean;
        moncount: byte;

begin
 pidname:=getpidname;
 moncount:=20;
 iamrunning:=am_i_running (pidname);
 oldpid:=loadpid (pidname);

 // Clean up in case of crash or hard reboot
 if (oldpid <> 0) and not iamrunning then
  begin
   writeln ('Removing stale PID file and SHM buffer');
   deletepid (pidname);
   shmname:=paramstr (0) + #0;
   shmoldkey:=ftok (pchar (@shmname[1]), oldpid);
   shmid:=shmget (shmoldkey, sizeof (TSHMVariables), 0);
   shmctl (shmid, IPC_RMID, nil);
   oldpid:=0; // PID was stale
  end;

 case lowercase (paramstr (1)) of
  'running':   if iamrunning then halt (0) else halt (1);
  'stop':      if iamrunning then fpkill (oldpid, SIGTERM);
  'beep':      senddaemoncommand (oldpid, CMD_BEEP, paramstr (2));
  'tuesday':   senddaemoncommand (oldpid, CMD_TUESDAY, paramstr (2));
  'open':      senddaemoncommand (oldpid, CMD_OPEN, '(cmdline): ' + paramstr (2));
  'disable':   senddaemoncommand (oldpid, CMD_DISABLE, paramstr (2));
  'enable':    senddaemoncommand (oldpid, CMD_ENABLE, paramstr (2));
  'diag':      dump_config (STATIC_CONFIG, STATIC_CONFIG_STR);
  'start':
    if iamrunning
     then writeln ('Already started as PID ', oldpid)
     else
      begin
       fpsigemptyset(zerosigs);
       { block all signals except -HUP & -TERM }
       sSet := $fffebffe;
       ps1 := @sSet;
       fpsigprocmask(sig_block,ps1,nil);
       { setup the signal handlers }
       new(aOld);
       new(aHup);
       new(aTerm);
       new(aChild);
       aTerm^.sa_handler := SigactionHandler(@signalhandler);
       aTerm^.sa_mask := zerosigs;
       aTerm^.sa_flags := 0;
       aTerm^.sa_restorer := nil;
       aHup^.sa_handler := SigactionHandler(@signalhandler);
       aHup^.sa_mask := zerosigs;
       aHup^.sa_flags := 0;
       aHup^.sa_restorer := nil;
       aChild^.sa_handler := SigactionHandler(@children_of_bodom);
       aChild^.sa_mask := zerosigs;
       aChild^.sa_flags := 0;
       aChild^.sa_restorer := nil;
       fpSigAction(SIGTERM,aTerm,aOld);
       fpSigAction(SIGHUP,aHup,aOld);
       fpSigAction(SIGCHLD,aChild,aOld);

       pid := fpFork;
       if pid = 0 then
        Begin // we're in the child
         openlog (pchar (format (ApplicationName + '[%d]', [fpgetpid])), LOG_NOWAIT, LOG_DAEMON);
         syslog (log_info, 'Spawned new process: %d'#10, [fpgetpid]);
         Close(system.input); // close stdin
         Close(system.output); // close stdout
         Assign(system.output,'/dev/null');
         ReWrite(system.output);
         Close(stderr); // close stderr
         Assign(stderr,'/dev/null');
         ReWrite(stderr);
         FpUmask (0);
         sid:=FpSetSid;
         syslog (log_info, 'Session ID: %d'#10, [sid]);
         FpChdir ('/');
        End
       Else
        Begin // We're in the parent
         writeln (applicationname, '[',fpgetpid,']: started background process ',pid);
         SavePid(pidname, pid);
         Halt; // successful fork, so parent dies
        End;
       // Running into the daemon
       godaemon (fpgetpid);
       deletepid (pidname); // cleanup
       closelog;
      end;
  'monitor': // Interactive monitor mode
    begin
     while (not iamrunning) and (moncount <> 0) do
      begin
       moncount:=moncount-1;
       iamrunning:=am_i_running (pidname);
       writeln ('Waiting for main process to come up (',moncount,')');
       sleep (500);
      end;
     if iamrunning then
      begin
       oldpid:=loadpid (pidname);
       writeln ('Found instance running as PID ', oldpid, ', launching monitor...');
       run_test_mode (oldpid);
      end
      else
      begin
       writeln ('Main process did not start. Bailing out.');
       halt (1);
      end;
     end;
  else
   begin
    writeln ('This is the main control program for The Black Knight, HSBXL front door controller.');
    if (paramstr (1) <> '') and (lowercase (paramstr (1)) <> 'help') then writeln ('ERROR: unknown parameter: ''', paramstr (1),'''.');
    writeln;
    writeln ('Usage: ', applicationname, ' [start|stop|tuesday|monitor|open|diag|running|enable|disable] [...]');
    writeln;
    writeln ('Command line parameters:');
    writeln ('  start      - Start the daemon');
    writeln ('  stop       - Stop the daemon');
    writeln ('  tuesday    - Start open mode (not implemented yet)');
    writeln ('  monitor    - Full screen monitor for debugging');
    writeln ('  open       - Open the door. Any extra parameter is logged to syslog as extra text');
    writeln ('  diag       - Dump configuration options');
    writeln ('  beep       - Chirp the buzzer. Any extra parameter is logged to syslog as extra text');
    writeln ('  running    - For script usage: tell if the main daemon is running (check exitcode: 0=running 1=not running)');
    writeln ('  enable     - Activate the locking system outputs');
    writeln ('  disable    - Deactivate the locking system outputs. Inputs still monitored.');
    halt (1);
   end;
 end;
end.
