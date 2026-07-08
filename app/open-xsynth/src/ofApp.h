#pragma once

#include <stdint.h>

#include "ofMain.h"
#include "ofxOsc.h"
#include "OledScreenDriver.h"
#include "ParticleScreen.h"
#include "RemoteScreen.h"
#include "InputThread.h"

#define HOST "localhost"
#define INPORT 8000
#define OUTPORT 8001

//--------------------------------------------------------
class ofApp : public ofBaseApp {

	public:

		void setup() override;
		void update() override;
		void draw() override;
		void exit() override;

		// poll inbound OSC and dispatch /oled/* drawing commands
		void readOscIn();

		void keyPressed(int key);
		void keyReleased(int key);
		void mouseMoved(int x, int y);
		void mouseDragged(int x, int y, int button);
		void mousePressed(int x, int y, int button);
		void mouseReleased(int x, int y, int button);
		void mouseEntered(int x, int y);
		void mouseExited(int x, int y);
		void windowResized(int w, int h);
		void gotMessage(ofMessage msg) override;
		void dragEvent(ofDragInfo dragInfo) override;

		// font type
		ofTrueTypeFont font;

		// OSC: oscOut here is only for mouse events; control input has its
		// own sender inside InputThread. oscIn receives /oled/* drawing.
		ofxOscSender oscOut;
		ofxOscReceiver oscIn;

	private:
		static constexpr int OLED_I2C_ADDR = 0x3d;
		static constexpr int MCU_I2C_ADDR = 0x47;
		static constexpr int OLED_BCM_RESET_PIN = 4;

		// dedicated MCU poller (own i2c fd + own OSC sender, ~200 Hz)
		InputThread inputThread;

		// main particle home screen
		ParticleScreen particleScreen;
		// screen driven by inbound OSC drawing commands
		RemoteScreen remoteScreen;
		// when true the remote screen owns the OLED (until /oled/release)
		bool remoteActive;

		// I2C device file descriptor (OLED only)
		int i2c;
		// offscreen buffer for rendering
		ofFbo fbo;
		// driver to send fbo to OLED screen
		OledScreenDriver oledScreenDriver;
};
