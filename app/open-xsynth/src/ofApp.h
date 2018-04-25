#pragma once

#include <stdint.h>

#include "ofMain.h"
#include "ofxOsc.h"
#include "AnalogInput.h"
#include "OledScreenDriver.h"
#include "ParticleScreen.h"
#include "VolumeScreen.h"

#define HOST "localhost"
#define INPORT 8000
#define OUTPORT 8001

//--------------------------------------------------------
class ofApp : public ofBaseApp {

	public:
//		ofApp();

		void setup() override;
		void update() override;

		// read hardware inputs from MCU
		void readInputs();
		void draw() override;
		// update grid selection
		void updateGridSelection(std::array<int, 2> selection);
		// init grid position
		void initGridSelection(std::array<int, 2> selection);
		// update rotary movement
		void updateRotary(int idx, int amount);
		// update potentiometer
		void updateAnalogInput(int idx, uint8_t value, bool force);
		// change current screen
		void setScreen(BaseScreen *screen);

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
		
		// handler for OSC messaging
		ofxOscSender oscOut;
		ofxOscReceiver oscIn;

	private:
		static constexpr int OLED_I2C_ADDR = 0x3d;
		static constexpr int MCU_I2C_ADDR = 0x47;
		static constexpr int OLED_BCM_RESET_PIN = 4;
		static constexpr int GRID_SIZE = 11;
		static constexpr float SCREEN_TIMEOUT = 1.0;

		// grid interpolation position
		std::array<int, 2> gridSelection;
		// state for grid touch
		bool gridState;
		bool gridPrevState;

		// 6 potentiometer values
		AnalogInput analogInputs[6];

		// main particle home
		ParticleScreen particleScreen;
		// volume adjustment screen
		VolumeScreen volumeScreen;

		// the active screen
		BaseScreen *currentScreen;
		// number of seconds before home screen timeout
		float currentScreenTimeout;

		// I2C device file descriptor
		int i2c;
		// offscreen buffer for rendering
		ofFbo fbo;
		// driver to send fbo to OLED screen
		OledScreenDriver oledScreenDriver;

		// format of data read from MCU
		struct InputsMessage{
			uint8_t touch[2];
			int8_t rotaries[4]; 	
			uint8_t potentiometers[6];
			uint32_t chk;
		};

		// previous InputsMessage read from MCU for comparison
		InputsMessage lastInputsMessage;
		// true if inputs from MCU have been read
		bool inputsRead;


};

