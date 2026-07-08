/*
Polls the MCU (touch grid, pots, encoders) over I2C on a dedicated thread at
~200 Hz and emits control OSC immediately on change — decoupling control
latency from the 30 fps render loop. Uses its own I2C fd and its own OSC sender
so it never contends with the main thread's OLED draw.
*/

#pragma once

#include "ofMain.h"
#include "ofxOsc.h"
#include "AnalogInput.h"
#include <array>
#include <cstdint>
#include <string>

class InputThread : public ofThread{
	public:
		// Opens the OSC sender + I2C device and starts polling.
		void start(const std::string &host, int outPort,
		           const char *i2cDev, uint8_t mcuAddr);
		void threadedFunction() override;

		// Latest touch-grid cell (thread-safe), for the particle screen.
		std::array<int, 2> getGrid();

	private:
		// Layout of the input report read from the MCU (Phase 2b: 16 input
		// bytes = 4 x uint32 + checksum). touch is sub-cell 0..250 (255 = no
		// touch); pressure is total coupling 0..254.
		struct InputsMessage{
			uint8_t touch[2];
			uint8_t pressure;
			uint8_t reserved0;
			int8_t  rotaries[4];
			uint8_t potentiometers[6];
			uint8_t reserved1[2];
			uint32_t chk;
		};
		// Reads one report; returns true if read + checksum are valid.
		bool readMcu(InputsMessage &msg);

		int i2c = -1;
		uint8_t mcuAddr = 0x47;
		ofxOscSender oscOut;
		AnalogInput analogInputs[6];
		InputsMessage last{};  // zero-init so the first read compares cleanly
		bool inited = false;

		static constexpr int GRID_SIZE = 11;
		std::array<int, 2> grid{ {5, 5} };  // shared, guarded by lock()
		bool gridState = false;
		bool gridPrevState = false;
};
