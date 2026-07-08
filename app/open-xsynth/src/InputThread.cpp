#include "InputThread.h"

#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>


void InputThread::start(const std::string &host, int outPort,
                        const char *i2cDev, uint8_t mcuAddr_){
	mcuAddr = mcuAddr_;
	oscOut.setup(host, outPort);
	i2c = open(i2cDev, O_RDWR);
	startThread();
}


bool InputThread::readMcu(InputsMessage &msg){
	if(i2c < 0){
		return false;
	}
	if(ioctl(i2c, I2C_SLAVE, mcuAddr) < 0){
		return false;
	}
	uint8_t zero[1] = {0};
	if(write(i2c, zero, 1) != 1){
		return false;
	}
	if(read(i2c, &msg, sizeof(msg)) != static_cast<ssize_t>(sizeof(msg))){
		return false;
	}
	uint32_t *src = reinterpret_cast<uint32_t *>(&msg);
	uint32_t chk = 0xaa55aa55;
	chk += src[0];
	chk += src[1];
	chk += src[2];
	chk += src[3];
	return chk == msg.chk;
}


void InputThread::threadedFunction(){
	while(isThreadRunning()){
		InputsMessage msg;
		if(readMcu(msg)){
			if(!inited){
				// Send the initial value of every pot once.
				for(int i=0; i<6; ++i){
					analogInputs[i].init(msg.potentiometers[i]);
					ofxOscMessage m;
					m.setAddress("/pot");
					m.addIntArg(i);
					m.addFloatArg(analogInputs[i].getNormalized());
					oscOut.sendMessage(m, false);
				}
			}else{
				// Pots: send on meaningful change.
				for(int i=0; i<6; ++i){
					if(analogInputs[i].update(msg.potentiometers[i], true)){
						ofxOscMessage m;
						m.setAddress("/pot");
						m.addIntArg(i);
						m.addFloatArg(analogInputs[i].getNormalized());
						oscOut.sendMessage(m, false);
					}
				}
				// Rotaries: send the (signed) delta when non-zero.
				for(int i=0; i<4; ++i){
					int8_t delta = msg.rotaries[i] - last.rotaries[i];
					if(delta){
						ofxOscMessage m;
						m.setAddress("/rotary");
						m.addIntArg(i);
						m.addIntArg(delta);
						oscOut.sendMessage(m, false);
					}
				}
			}

			// Touch grid (Phase 2b: sub-cell 0..250, 255 = no touch).
			int rawX = msg.touch[0];
			int rawY = msg.touch[1];
			ofxOscMessage m;
			bool touched = (rawX != 0xff && rawY != 0xff);
			if(touched){
				float fx = rawX / 25.0f;            // continuous 0..10
				float fy = rawY / 25.0f;
				float press = msg.pressure / 254.0f; // 0..1

				if(!gridPrevState){
					m.clear(); m.setAddress("/grid/touch"); m.addIntArg(1);
					oscOut.sendMessage(m, false);
					gridPrevState = true;
				}

				// Continuous position, sent on change.
				if(rawX != last.touch[0] || rawY != last.touch[1]){
					m.clear(); m.setAddress("/grid/pos");
					m.addFloatArg(fx); m.addFloatArg(fy);
					oscOut.sendMessage(m, false);

					// Quantised cell for the particle screen + /grid/xy compat.
					int cx = static_cast<int>(fx + 0.5f);
					int cy = static_cast<int>(fy + 0.5f);
					lock();
					bool moved = (grid[0] != cx || grid[1] != cy);
					grid[0] = cx; grid[1] = cy;
					unlock();
					if(moved){
						m.clear(); m.setAddress("/grid/xy");
						m.addIntArg(cx); m.addIntArg(cy);
						oscOut.sendMessage(m, false);
					}
				}

				// Pressure, sent on change.
				if(msg.pressure != last.pressure){
					m.clear(); m.setAddress("/grid/pressure");
					m.addFloatArg(press);
					oscOut.sendMessage(m, false);
				}
			}else{
				if(gridPrevState){
					m.clear(); m.setAddress("/grid/touch"); m.addIntArg(0);
					oscOut.sendMessage(m, false);
					gridPrevState = false;
				}
			}

			inited = true;
			last = msg;
		}

		ofSleepMillis(5);  // ~200 Hz
	}
}


std::array<int, 2> InputThread::getGrid(){
	lock();
	std::array<int, 2> g = grid;
	unlock();
	return g;
}
