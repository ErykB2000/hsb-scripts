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
{
 TODO:
 - Daemon mode
   * start/stop
   * Program name: /proc/<pid>/comm = basename (paramstr (0))

}

uses PiGpio, sysutils, crt, keyboard, strutils, baseunix, ipc;

TYPE    TDbgArray= ARRAY [0..15] OF string[15];
        TRegisterbits=bitpacked array [0..15] of boolean; // Like a word: a 16 bits bitfield
        TLotsofbits=bitpacked array [0..63] of boolean; // A shitload of bits to abuse. 64 bits should be enough. :-)
        TSHMVariables=RECORD // What items should be exposed for IPC.
                PIDofmain:TPid;
                Input, output: TRegisterbits;
                state, Config, command:TLotsofbits;
                Opendoormsg:string;
                end;

CONST   CLOCKPIN=7;  // 74LS673 pins
        STROBEPIN=8;
        DATAPIN=25;
        READOUTPIN=4; // Output of 74150

        bits:array [false..true] of char=('0', '1');
        // Hardware bug: i got the address lines reversed while building the board.
        // Using a lookup table to mirror the address bits
        BITMIRROR: array[0..15] of byte=(0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15);

        // Available outputs on 74LS673. Outputs Q0 to Q3 are connected to the address inputs of the 74150
        Q15=0; Q14=1; Q13=2; Q12=3; Q11=4; Q10=5; Q9=6; Q8=7; Q7=8; Q6=9; Q5=10; Q4=11;
        // Use more meaningful descriptions of the outputs in the code
        // Outputs Q4, Q12, Q13, Q14 and Q15 are not used for the moment. Status LED maybe ?
        BUZZER_OUPUT_TRANSISTOR=Q11;
        BATTERY_RELAY=Q10;
        MAGLOCK1_RELAY=Q9;
        MAGLOCK2_RELAY=Q8;
        DOOR_STRIKE_RELAY=Q7;
        LIGHT_CONTROL_RELAY=Q6;
        DOORBELL_INHIBIT_RELAY=Q5;
        // Available inputs from the 74150
        I15=15; I14=14; I13=13; I12=12; I11=11; I10=10; I9=9; I8=8; I7=7; I6=6; I5=5; I4=4; I3=3; I2=2; I1=1; I0=0;
        // Use more meaningful descriptions of the inputs in the code
        // Inputs OPTO4, IN3, IN2 and IN1 are not used for the moment.
        IN11=I0; IN10=I1; IN9=I2; IN8=I3; IN7=I4; IN6=I5; IN5=I6; IN4=I7; IN3=I8; IN2=I9; IN1=I10; OPTO1=I12; OPTO2=I13; OPTO3=I14; OPTO4=I15;
        PANIC_SENSE=I11;
        DOORBELL1=OPTO1;
        DOORBELL2=OPTO2;
        DOORBELL3=OPTO3;
        BOX_TAMPER_SWITCH=IN11;
        TRIPWIRE_LOOP=IN10;
        MAGLOCK1_RETURN=IN9;
        MAGLOCK2_RETURN=IN8;
        DOORHANDLE=IN7;
        LIGHTS_ON_SENSE=IN6;
        DOOR_CLOSED_SWITCH=IN5;
        MAIL_DETECTION=IN4;     // Of course we'll have physical mail notification. :-)
        IS_CLOSED=false;
        IS_OPEN=true;
        DBGINSTATESTR: Array [IS_CLOSED..IS_OPEN] of string[5]=('closed', 'open');
        DBGOUTSTATESTR: Array [false..true] of string[5]=('On', 'Off');
        DBGOUT: TDbgArray=('Q15 not used', 'Q14 not used', 'Q13 not used', 'Q12 not used', 'buzzer', 'battery', 'mag1 power', 'mag2 power', 'strike',
                                'light', 'bell inhib.', 'Q4 not used', '74150 A3', '74150 A2', '74150 A1', '74150 A0');
        DBGIN: TDbgArray=('TAMPER BOX','TRIPWIRE','MAG1 CLOSED','MAG2 CLOSED','HANDLE','LIGHT ON','DOOR SWITCH','MAILBOX','IN 3',
                                'IN 2','IN 1','PANIC SWITCH','DOORBELL 1','DOORBELL 2','DOORBELL 3','OPTO 4');
        // offsets in status bitfield
        S_MAGLOCK1=0; S_MAGLOCK2=1; S_TRIPWIRE_LOOP=2; S_TAMPER_SWITCH=3; S_MAILBOX=4;


VAR     GPIO_Driver: TIODriver;
        GpF: TIOPort;
        QUIT: boolean;

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

///////////// DEBUG FUNCTIONS /////////////

function debug_alterinput(inbits: TRegisterbits): TRegisterbits;
var key: string;
    K: TKeyEvent;
begin
 K:=PollKeyEvent; // Check for keyboard input
 if k<>0 then // Key pressed ?
  begin
   k:=TranslateKeyEvent (GetKeyEvent);
   key:= KeyEventToString (k);
   case key of
    '0': if inbits[0] then inbits[0]:=false else inbits[0]:=true;
    '1': if inbits[1] then inbits[1]:=false else inbits[1]:=true;
    '2': if inbits[2] then inbits[2]:=false else inbits[2]:=true;
    '3': if inbits[3] then inbits[3]:=false else inbits[3]:=true;
    '4': if inbits[4] then inbits[4]:=false else inbits[4]:=true;
    '5': if inbits[5] then inbits[5]:=false else inbits[5]:=true;
    '6': if inbits[6] then inbits[6]:=false else inbits[6]:=true;
    '7': if inbits[7] then inbits[7]:=false else inbits[7]:=true;
    '8': if inbits[8] then inbits[8]:=false else inbits[8]:=true;
    '9': if inbits[9] then inbits[9]:=false else inbits[9]:=true;
    'a': if inbits[10] then inbits[10]:=false else inbits[10]:=true;
    'b': if inbits[11] then inbits[11]:=false else inbits[11]:=true;
    'c': if inbits[12] then inbits[12]:=false else inbits[12]:=true;
    'd': if inbits[13] then inbits[13]:=false else inbits[13]:=true;
    'e': if inbits[14] then inbits[14]:=false else inbits[14]:=true;
    'f': if inbits[15] then inbits[15]:=false else inbits[15]:=true;
    'q': QUIT:=true;
    else writeln ('Invalid key: ',key);
   end;
  end;
 debug_alterinput:=inbits;
end;

// Decompose a word into bitfields with description
procedure debug_showbits (inputbits: TRegisterbits; screenshift: byte; description: TDbgArray );
var i: byte;
begin
 for i:=0 to 15 do
  begin
   description[i][0]:=char (15);// Trim length
   gotoxy (1 + screenshift, i + 1); write ( bits[inputbits[i]], ' ', description[i]);
//   sleep (20);
  end;
  writeln;
end;

///////////// CHIP HANDLING FUNCTIONS /////////////

// Send out a word to the 74LS673
procedure write74673 (clockpin, datapin, strobepin: byte; data: TRegisterbits);
var i: byte;
begin
 for i:=0 to 15 do
 begin
  GpF.SetBit (clockpin);
  if data[i] then GpF.SetBit (datapin) else GpF.Clearbit (datapin);
  GpF.ClearBit (clockpin);
 end;
// GpF.SetBit (datapin); // Is that line needed ?
 GpF.SetBit (strobepin);
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
   sleep (1);
   gpioword:=(gpioword or (ord (GpF.GetBit (readout)) shl graycode(i) ) );
  end;
 io_673_150:=word2bits (gpioword);
end;

///////////// MAIN BLOCK /////////////
var  ii: byte;
     shmkey:TKey;
     shmid: longint;
     progname:string;
     inputs, outputs, oldin, oldout: TRegisterbits;
     SHMdata: TSHMVariables;
     state: TLotsofbits;

begin
 fillchar (SHMdata, sizeof (SHMData), 0);
 outputs:=word2bits (0);
 oldin:=word2bits (12345);
 oldout:=word2bits (12345);
 progname:=paramstr (0) + #0;
 shmkey:=ftok (pchar (@progname[1]), ord ('t'));
 shmid:=shmget (shmkey, sizeof (TSHMVariables), IPC_CREAT or IPC_EXCL or 438);
 QUIT:=false;

 case paramstr (1) of
  'start':
   begin
    if shmid = -1 then
     begin
      writeln (paramstr (0),' already running as PID ', SHMData.PIDOfmain);
      halt (1);
     end;
{
   if not GPIO_Driver.MapIo then // No GPIO ?
    begin
     writeln('Error mapping gpio registry');
     halt (1);
    end;
   GpF := GpIo_Driver.CreatePort(GPIO_BASE, CLOCK_BASE, GPIO_PWM);
   GpF.SetPinMode (CLOCKPIN, OUTPUT);
   GpF.setpinmode (STROBEPIN, OUTPUT);
   GpF.setpinmode (DATAPIN, OUTPUT);
   GpF.setpinmode (READOUTPIN, INPUT);

   repeat
   inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, outputs);

   until false;
}
    shmctl (shmid, IPC_RMID, nil);
   end;

   'test':
   begin
    if shmid = -1 then
     begin
      writeln (paramstr (0),' already running as PID ', SHMData.PIDOfmain);
      halt (1);
     end;
    initkeyboard;
    clrscr;
    repeat
//   inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, outputs);
     for ii:=0 to 11 do
      begin
       inputs:=debug_alterinput (inputs);
       debug_showbits (word2bits (1 shl ii), 0, DBGOUT);
       debug_showbits (inputs, 25, DBGIN);
       writeln ('cycle up  : ', hexstr (ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), '.');
      end;
     for ii:=11 downto 0 do
     begin
      debug_showbits (word2bits (1 shl ii), 0, DBGOUT);
      debug_showbits (inputs, 25, DBGIN);
      writeln ('cycle down: ', hexstr(ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), '.');
     end;
     oldout:=outputs;
     oldin:=inputs;
    until QUIT;
    donekeyboard;
    shmctl (shmid, IPC_RMID, nil);
   end;

   'testpattern':
   begin
   if not GPIO_Driver.MapIo then
    begin
     writeln('Error mapping gpio registry');
     halt (1);
    end;
   GpF := GpIo_Driver.CreatePort(GPIO_BASE, CLOCK_BASE, GPIO_PWM);
   GpF.SetPinMode (CLOCKPIN, OUTPUT);
   GpF.setpinmode (STROBEPIN, OUTPUT);
   GpF.setpinmode (DATAPIN, OUTPUT);
   GpF.setpinmode (READOUTPIN, INPUT);
   repeat
   inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, outputs);
    for ii:=0 to 11 do
     begin
      writeln ('cycle up  : ', hexstr (ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), ', read: ', bits2str (io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, word2bits (1 shl ii))), '.');
     end;
    for ii:=11 downto 0 do
     begin
      writeln ('cycle down: ', hexstr (ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), ', read: ', bits2str (io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, word2bits (1 shl ii))), '.');
     end;
    until false;
   end;

   '':
   begin
    writeln ('Usage: ', paramstr (0), ' [start|stop|test|open|diag]');
    halt (1);
   end;
 end;
// writeln;writeln;

end.