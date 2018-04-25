/*
Copyright 2017 Google Inc. All Rights Reserved.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include "OledScreenDriver.h"

#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>


bool OledScreenDriver::setup(int i2cFd_, uint8_t address_, int resetPin){
	i2cFd = i2cFd_;
	address = address_;

	if(i2cFd < 0){
		return false;
	}
	if(ioctl(i2cFd, I2C_SLAVE, address) < 0){
		return false;
	}

	// First use the reset pin to reset the screen.
	reset(resetPin);

	// Now send the screen setup commands.
	static uint8_t setup0[] = {
		0, 174, 213, 128, 168, 63, 211, 0, 64, 141, 20, 32,
		0, 161, 200, 218, 18, 217, 241, 219, 64, 164, 166
	};
	static uint8_t setup1[] = {
		0, 129, 207
	};
	static uint8_t setup2[] = {
		0, 33, 0, 127, 34, 0, 7
	};

	if(write(i2cFd, setup0, sizeof(setup0)) != sizeof(setup0)){
		return false;
	}
	if(write(i2cFd, setup1, sizeof(setup1)) != sizeof(setup1)){
		return false;
	}
	if(write(i2cFd, setup2, sizeof(setup2)) != sizeof(setup2)){
		return false;
	}

	return true;
}


void OledScreenDriver::draw(ofFbo &fbo){
	if(i2cFd < 0){
		return;
	}
	if(ioctl(i2cFd, I2C_SLAVE, address) < 0){
		return;
	}

	ofPixels pixels;
	fbo.readToPixels(pixels);

	uint8_t buf[129];

	// Write data command.
	buf[0] = 64;

	int pixelIdx = 0;
	for(int seg=0; seg<8; ++seg){
		// The screen is drawn in 8 horizontal segments.
		// Each segment is 128x8 pixels.
		// Each byte represents one column.

		// Clear the buffer first.
		for(unsigned int x=1; x<sizeof(buf); ++x){
			buf[x] = 0;
		}

		// Traverse the 8 rows.
		for(int y=0; y<8; ++y){
			for(int x=0; x<128; ++x){
				int set = pixels[pixelIdx] >= 127;
				buf[x+1] |= set << y;
				pixelIdx += 4;
			}
		}

		if(write(i2cFd, buf, sizeof(buf)) != sizeof(buf)){
			break;
		}
	}

	// Flush the new data to the screen.
	static uint8_t flush[] = {
		0, 175
	};

	if(write(i2cFd, flush, sizeof(flush)) != sizeof(flush)){
		return;
	}
}


void OledScreenDriver::reset(int resetPin){
	constexpr int INPUT = 1;
	constexpr int OUTPUT = 1;
	constexpr int SET = 7;
	constexpr int CLEAR = 10;
	constexpr int MAP_SIZE = 0xb4;

	if(resetPin < 0){
		return;
	}

	// Mmap the GPIO device to access the pins.
	int fd = open("/dev/gpiomem", O_RDWR | O_SYNC);
	if(fd < 0){
		return;
	}

	volatile uint32_t *gpioReg = (uint32_t *)mmap(
			NULL, MAP_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);

	close(fd);

	if(gpioReg == MAP_FAILED){
		return;
	}

	// Sets the mode to either INPUT or OUTPUT.
	auto setMode = [&](int mode){
		int reg = resetPin / 10;
		int shift = (resetPin % 10) * 3;

		gpioReg[reg] = (gpioReg[reg] & ~(7<<shift)) | (mode<<shift);
	};

	// Sets the level to high (1) or low (0).
	auto writeLevel = [&](int level){
		int bank = resetPin >> 5;
		int val = 1 << (resetPin & 0x1f);
		if(level){
			gpioReg[bank+SET] = val;
		}else{
			gpioReg[bank+CLEAR] = val;
		}
	};

	// Drive the reset pin low for 1ms.
	setMode(OUTPUT);
	writeLevel(0);
	usleep(1000);
	writeLevel(1);

	// Then change it back to an input and wait for the screen to initialise.
	setMode(INPUT);
	usleep(1000);

	munmap(const_cast<uint32_t *>(gpioReg), MAP_SIZE);
}
