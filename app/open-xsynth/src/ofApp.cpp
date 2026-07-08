#include <unistd.h>
#include <fcntl.h>

#include "ofApp.h"

//--------------------------------------------------------------
void ofApp::setup(){

	ofBackground(30, 30, 30);

	// oscOut here is only for mouse events; oscIn receives /oled/* drawing.
	oscOut.setup(HOST, OUTPORT);
	oscIn.setup(INPORT);

	remoteActive = false;

	// open i2c interface for the OLED (the input thread opens its own fd)
	i2c = open("/dev/i2c-1", O_RDWR);
	oledScreenDriver.setup(i2c, OLED_I2C_ADDR, OLED_BCM_RESET_PIN);

	// set oled buffer
	fbo.allocate(BaseScreen::SCREEN_WIDTH, BaseScreen::SCREEN_HEIGHT, GL_RGBA);
	ofSetFrameRate(30);

	// start the dedicated MCU poller (control OSC out at ~200 Hz)
	inputThread.start(HOST, OUTPORT, "/dev/i2c-1", MCU_I2C_ADDR);
}

//--------------------------------------------------------------
void ofApp::update(){
	readOscIn();
}

//--------------------------------------------------------------
void ofApp::exit(){
	inputThread.waitForThread(true, 1000);
}

//--------------------------------------------------------------
// Reads a float arg whether the sender encoded it as int or float, so
// clients in any language don't have to worry about OSC numeric typing.
static float oscArgF(ofxOscMessage &m, int i){
	if(i >= static_cast<int>(m.getNumArgs())){
		return 0.0f;
	}
	if(m.getArgType(i) == OFXOSC_TYPE_INT32){
		return static_cast<float>(m.getArgAsInt32(i));
	}
	if(m.getArgType(i) == OFXOSC_TYPE_FLOAT){
		return m.getArgAsFloat(i);
	}
	return 0.0f;
}

//--------------------------------------------------------------
void ofApp::readOscIn(){
	while(oscIn.hasWaitingMessages()){
		ofxOscMessage m;
		oscIn.getNextMessage(m);
		const std::string a = m.getAddress();

		if(a == "/oled/clear"){
			remoteScreen.beginFrame();
		}else if(a == "/oled/show"){
			remoteScreen.showFrame();
			remoteActive = true;
		}else if(a == "/oled/release"){
			remoteActive = false;
		}else if(a == "/oled/brightness"){
			float v = oscArgF(m, 0);
			uint8_t b = (v <= 1.0f)
				? static_cast<uint8_t>(ofClamp(v * 255.0f, 0, 255))
				: static_cast<uint8_t>(ofClamp(v, 0, 255));
			oledScreenDriver.setBrightness(b);
		}else if(a == "/oled/invert"){
			oledScreenDriver.setInvert(oscArgF(m, 0) > 0.5f);
		}else if(a == "/oled/text"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Text;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			if(m.getNumArgs() > 2 && m.getArgType(2) == OFXOSC_TYPE_STRING){
				c.s = m.getArgAsString(2);
			}
			remoteScreen.addCmd(c);
		}else if(a == "/oled/line"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Line;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			c.c = oscArgF(m, 2); c.d = oscArgF(m, 3);
			remoteScreen.addCmd(c);
		}else if(a == "/oled/rect"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Rect;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			c.c = oscArgF(m, 2); c.d = oscArgF(m, 3); c.e = oscArgF(m, 4);
			remoteScreen.addCmd(c);
		}else if(a == "/oled/circle"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Circle;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			c.c = oscArgF(m, 2); c.d = oscArgF(m, 3);
			remoteScreen.addCmd(c);
		}else if(a == "/oled/pixel"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Pixel;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			remoteScreen.addCmd(c);
		}else if(a == "/oled/bar"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Bar;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			c.c = oscArgF(m, 2); c.d = oscArgF(m, 3); c.e = oscArgF(m, 4);
			remoteScreen.addCmd(c);
		}else if(a == "/oled/scrolltext"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::ScrollText;
			c.b = oscArgF(m, 0);  // y
			if(m.getNumArgs() > 1 && m.getArgType(1) == OFXOSC_TYPE_STRING){
				c.s = m.getArgAsString(1);
			}
			c.e = oscArgF(m, 2);  // speed (px/sec)
			remoteScreen.addCmd(c);
		}else if(a == "/oled/bitmap"){
			RemoteScreen::Cmd c; c.op = RemoteScreen::Op::Bitmap;
			c.a = oscArgF(m, 0); c.b = oscArgF(m, 1);
			c.c = oscArgF(m, 2); c.d = oscArgF(m, 3);
			int w = static_cast<int>(c.c);
			int h = static_cast<int>(c.d);
			if(w > 0 && h > 0 && m.getNumArgs() > 4 &&
			   m.getArgType(4) == OFXOSC_TYPE_BLOB){
				ofBuffer buf = m.getArgAsBlob(4);
				const unsigned char *bits =
					reinterpret_cast<const unsigned char *>(buf.getData());
				size_t nbits = static_cast<size_t>(w) * h;
				size_t nbytes = buf.size();
				c.blob.assign(nbits, 0);
				for(size_t i=0; i<nbits; ++i){
					size_t byte = i >> 3;
					int bit = 7 - static_cast<int>(i & 7);
					unsigned char on =
						(byte < nbytes) ? ((bits[byte] >> bit) & 1) : 0;
					c.blob[i] = on ? 255 : 0;
				}
				remoteScreen.addCmd(c);
			}
		}
	}
}

//--------------------------------------------------------------
void ofApp::draw(){
	double elapsed = ofGetLastFrameTime();

	std::array<int, 2> sel = inputThread.getGrid();
	particleScreen.updateParticles(
		{(float)sel[0], (float)sel[1]}, elapsed);

	// render into fbo
	fbo.begin();
	ofClear(0, 0, 0, 0);
	ofSetColor(255, 255, 255);

	if(remoteActive){
		remoteScreen.draw(elapsed);
	}else{
		particleScreen.draw(elapsed);
	}

	fbo.end();

	// show fbo for dev
	ofClear(0, 0, 0, 0);
	ofSetColor(255, 255, 255);
	fbo.draw(0, 0);

	// send fbo to the OLED screen (dirty-checked internally)
	oledScreenDriver.draw(fbo);
}

//--------------------------------------------------------------
void ofApp::keyPressed(int key){
}

//--------------------------------------------------------------
void ofApp::keyReleased(int key){
}

//--------------------------------------------------------------
void ofApp::mouseMoved(int x, int y){
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
