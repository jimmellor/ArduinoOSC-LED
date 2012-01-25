// Some of this blatantly plagiarised from http://wiki.dingfabrik.de/index.php/OSC

#include <SPI.h>
#include <Ethernet.h> // version IDE 0022
#include <Bounce.h>

#include <Z_OSC.h> // uses Z_OSC https://github.com/djiamnot/Z_OSC

byte myMac[] = { 
  0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };
byte myIp[]  = { 
  192, 168, 1, 10 };
int  rcvPort  = 10000;

byte destIp[] =  { 
  192, 168, 1, 111 };
int  destPort = 10000;

// Variables for switch/debounce

// Variables will change:
int btnState0 = LOW;             // the current reading from the input pin
int btnState1 = LOW;             // the previous reading from the input pin
int lastBtnState0 = LOW;             // the current reading from the input pin
int lastBtnState1 = LOW;             // the previous reading from the input pin

int LEDState = LOW;


// Digital pins connected to switch
const int btn0 = 6;
const int btn1 = 7;

// Debounced button objects
Bounce bbtn0 = Bounce( btn0, 25 );
Bounce bbtn1 = Bounce( btn1, 25 );


// Button OSC addresses
char jamPodBtn0[] = "/exile/jampod/box/btn/0";
char jamPodBtn1[] = "/exile/jampod/box/btn/1";

// BlinkM OSC addresses

char blinkMRAddr[] = "/ard/red";
char blinkMGAddr[] = "/ard/green";
char blinkMBAddr[] = "/ard/blue";

char micPodR[] = "/exile/micpod/red";
char micPodG[] = "/exile/micpod/green";
char jamPodR[] = "/exile/jampod/red";
char jamPodG[] = "/exile/jampod/green";
char jamPodLED0[] = "/exile/jampod/box/led/0";
char jamPodLED1[] = "/exile/jampod/box/led/1";

// Initialise the OSC-Servers

Z_OSCServer server;
Z_OSCMessage *rcvMes;

// Initialise the OSC-Client
Z_OSCClient client;

void setup(){
  //setup input pins - not needed if using the Bounce library
  //pinMode(btn0, INPUT);      // sets the digital pin as output
  //pinMode(btn1, INPUT);
  
  //setup output pins
  pinMode(A0, OUTPUT);      // sets the digital pin as output
  pinMode(A1, OUTPUT);
  pinMode(A2, OUTPUT);
  pinMode(A3, OUTPUT);
  pinMode(A4, OUTPUT);
  pinMode(A5, OUTPUT);

  Serial.begin(19200);

  Ethernet.begin(myMac ,myIp);
  
   // OSC-Socket opening 
   server.sockOpen(rcvPort);

}

void loop(){
  
  // Update and read the state of the switch into a local variable:
  
  bbtn0.update();
  bbtn1.update();
  
  int btnState0 = bbtn0.read();
  int btnState1 = bbtn1.read();
  //int btnState0 = digitalRead(btn0);
  //int btnState1 = digitalRead(btn1);

  // If either switch changed:
  if (btnState0 != lastBtnState0) {
    //Serial.print("0:");
    //Serial.println(btnState0);
    sendOSCMsg(jamPodBtn0, btnState0);
  } 
  if (btnState1 != lastBtnState1) {
    //Serial.print("1:");
    //  Serial.println(btnState1);
    sendOSCMsg(jamPodBtn1, btnState1);
  } 
  // send an OSC message using the state of the button:


  // save the reading.  Next time through the loop,
  // it'll be the lastBtnState0/1:
  lastBtnState0 = btnState0;
  lastBtnState1 = btnState1;

  // If there's a message on the OSC server...
  if(server.available()){
    //Serial.print("server avail");
    // ...will read this ...
    rcvMes=server.getMessage();
    // ...and processed in the function 'blinkRGB()'.
    outLED(rcvMes->getZ_OSCAddress(),rcvMes->getFloat(0));  
  }
  //add a timing delay to the loop,
  delay(10);
}


void sendOSCMsg(char* oscAdr, int btnState){

  Z_OSCMessage message;

  long int tmp=(long int)btnState; 

  message.setAddress(destIp,destPort);

  message.setZ_OSCMessage(oscAdr ,"i" , &tmp);

  client.send(&message);


}

void outLED(String text,float val){
  Serial.print(text);
  Serial.print(" => ");
  Serial.println(val);
  // This function gets handed over in the first parameter 'text' the path to the OSC and the second variable parameter 'val' to the value of this variable
  // Here, initially takes only a comparison of the variable name instead of some predefined names
  
  if(val== 1.0 ){
    int LEDState = HIGH;
  }
  else if(val== 0.0 ){
    int LEDState = LOW;   
  }
  

  if(text== micPodR){
    digitalWrite(A1, val);
  }
  else if(text== micPodG){
    digitalWrite(A0, val);
  }
  else if(text== jamPodR){
    digitalWrite(A3, val);
  }
  else if(text== jamPodG){
    digitalWrite(A2, val);
  }
  else if(text== jamPodLED0){
    digitalWrite(A4, val);
  }
  else if(text== jamPodLED1){
    digitalWrite(A5, val);
  }
}


