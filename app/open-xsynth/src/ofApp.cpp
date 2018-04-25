#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>

#include "ofApp.h"

//--------------------------------------------------------------
void ofApp::setup(){

	ofBackground(30, 30, 30);

	// open OSC  connections to HOST:OUTPORT/INPORT
	oscOut.setup(HOST, OUTPORT);
	oscIn.setup(INPORT);

	/*
	for(int idx=0; idx<4; ++idx){
		particleScreen.setInstrument(
			idx, instrumentScreens[idx].getCurrent().abbr);
	}*/
	setScreen(&particleScreen);

	// open i2c interface
	i2c = open("/dev/i2c-1", O_RDWR);
	oledScreenDriver.setup(i2c, OLED_I2C_ADDR, OLED_BCM_RESET_PIN);

	// init grid position to center
	gridSelection = {5, 5};	
	updateGridSelection(gridSelection);
	initGridSelection(gridSelection);

	// read inputs
	inputsRead = false;
	readInputs();
	
	// set oled buffer
	fbo.allocate(BaseScreen::SCREEN_WIDTH, BaseScreen::SCREEN_HEIGHT, GL_RGBA);
	ofSetFrameRate(30);
}

//--------------------------------------------------------------
void ofApp::update(){
	readInputs();

}

//--------------------------------------------------------------
void ofApp::readInputs(){
	if(i2c < 0){
		return;
	}

	// swich to MCU address
	if(ioctl(i2c, I2C_SLAVE, MCU_I2C_ADDR) < 0){
		return;
	}

	// read SMBus from address 0
	uint8_t buf[1] = {0};
	if(write(i2c, buf, 1) != 1){
		return;
	}

	// read whole input from MCU
	InputsMessage message;
	if(read(i2c, &message, sizeof(message)) != sizeof(message)){
		return;
	}

	// check checksum
	uint32_t *src = reinterpret_cast<uint32_t *>(&message);
	uint32_t chk = 0xaa55aa55;
	chk += src[0];
	chk += src[1];
	chk += src[2];
	if(chk != message.chk){
		return;
	}
	
	if(!inputsRead){
		// set init values of analog inputs
		for(int i=0; i<6; ++i){
			analogInputs[i].init(message.potentiometers[i]);

			ofxOscMessage m;
			m.setAddress("/pot");
			m.addIntArg(i);
			m.addFloatArg(analogInputs[i].getNormalized());
			oscOut.sendMessage(m, false);

		}
	}else{
		// update analog inputs
		for(int i=0; i<6; ++i){
			updateAnalogInput(i, message.potentiometers[i], false);
		}

		// update rotaries
		for(int i=0; i<4; ++i){
			int8_t delta = message.rotaries[i] - lastInputsMessage.rotaries[i];
			updateRotary(i, delta);
			
		}
	}

	updateGridSelection({message.touch[0], message.touch[1]});
	
	inputsRead = true;
	lastInputsMessage = message;
	
}

//--------------------------------------------------------------
void ofApp::draw(){
	double elapsed = ofGetLastFrameTime();
	
	particleScreen.updateParticles(
		{(float)gridSelection[0], (float)gridSelection[1]},
		elapsed);

	// render into fbo
	fbo.begin();
	ofClear(0, 0, 0, 0);
	ofSetColor(255, 255, 255);

	// switch back to particle screen on timeout
	if(currentScreenTimeout > 0.0){
		currentScreenTimeout -= elapsed;
		if(currentScreenTimeout <= 0.0){
			currentScreen = &particleScreen;
		}
	}
	currentScreen->draw(elapsed);

	fbo.end();

	// show fbo for dev
	ofClear(0, 0, 0 ,0);
	ofSetColor(255, 255, 255);
	fbo.draw(0, 0);

	// send fbo to the OLED screen
	oledScreenDriver.draw(fbo);

}

//--------------------------------------------------------------
void ofApp::updateGridSelection(std::array<int, 2> selection){
	int x = selection[0];
	int y = selection[1];

	ofxOscMessage m;

	if(x >= 0 && x < GRID_SIZE && y >= 0 && y < GRID_SIZE){

		gridState = true;

		if(gridState != gridPrevState){
			m.clear();
			m.setAddress("/grid/touch");
			m.addIntArg(1);
			oscOut.sendMessage(m, false);

			gridPrevState = true;
		}
		
		if(gridSelection != selection){	
			gridSelection = selection;

			m.clear();
			m.setAddress("/grid/xy");
			m.addIntArg(x);
			m.addIntArg(y);
			oscOut.sendMessage(m, false);
		}

		setScreen(&particleScreen);
	}else{
		gridState = false;

		if(gridState != gridPrevState){
			m.clear();
			m.setAddress("/grid/touch");
			m.addIntArg(0);
			oscOut.sendMessage(m, false);

			gridPrevState = false;

		}
	
	}
}

//--------------------------------------------------------------
void ofApp::initGridSelection(std::array<int, 2> selection){
	int x = selection[0];
	int y = selection[1];

	ofxOscMessage m;

	m.setAddress("/grid/xy");
	m.addIntArg(x);
	m.addIntArg(y);
	oscOut.sendMessage(m, false);

}

//--------------------------------------------------------------
void ofApp::updateRotary(int idx, int amount){
	if(amount){
		ofxOscMessage m;
		m.setAddress("/rotary");
		m.addIntArg(idx);
		m.addIntArg(amount);
		oscOut.sendMessage(m, false);
	}
}
		
//--------------------------------------------------------------
void ofApp::updateAnalogInput(int idx, uint8_t value, bool force){
	bool changed = analogInputs[idx].update(value, true);
	float normalized = analogInputs[idx].getNormalized();
	
	if(changed || force){
		ofxOscMessage m;
		m.setAddress("/pot");
		m.addIntArg(idx);
		m.addFloatArg(normalized);
		oscOut.sendMessage(m, false);
	}

}

//--------------------------------------------------------------
void ofApp::setScreen(BaseScreen *screen){
	currentScreen = screen;
	if(screen == &particleScreen){
		currentScreenTimeout = 0.0;
	}else{
		currentScreenTimeout = SCREEN_TIMEOUT;
	}
}

//--------------------------------------------------------------
void ofApp::keyPressed(int key){
/*	if(key == 'a' || key == 'A'){
		ofxOscMessage m;
		m.setAddress("/test");
		m.addIntArg(1);
		m.addFloatArg(3.5f);
		m.addStringArg("hello");
		m.addFloatArg(ofGetElapsedTimef());
		sender.sendMessage(m, false);
	}
    
*/

}

//--------------------------------------------------------------
void ofApp::keyReleased(int key){

}

//--------------------------------------------------------------
void ofApp::mouseMoved(int x, int y){
/*	ofxOscMessage m;
	m.setAddress("/mouse/position");
	m.addIntArg(x);
	m.addIntArg(y);
	oscOut.sendMessage(m, false);
*/
}

//--------------------------------------------------------------
void ofApp::mouseDragged(int x, int y, int button){

}

//--------------------------------------------------------------
void ofApp::mousePressed(int x, int y, int button){
	ofxOscMessage m;
	m.setAddress("/mouse/button");
	m.addIntArg(button);
	m.addStringArg("down");
	oscOut.sendMessage(m, false);

}

//--------------------------------------------------------------
void ofApp::mouseReleased(int x, int y, int button){
	ofxOscMessage m;
	m.setAddress("/mouse/button");
	m.addIntArg(button);
	m.addStringArg("up");
	oscOut.sendMessage(m, false);

}

//--------------------------------------------------------------
void ofApp::mouseEntered(int x, int y){

}

//--------------------------------------------------------------
void ofApp::mouseExited(int x, int y){

}

//--------------------------------------------------------------
void ofApp::windowResized(int w, int h){

}

//--------------------------------------------------------------
void ofApp::gotMessage(ofMessage msg){

}

//--------------------------------------------------------------
void ofApp::dragEvent(ofDragInfo dragInfo){
    
}

