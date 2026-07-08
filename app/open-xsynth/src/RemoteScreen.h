/*
A screen driven entirely by inbound OSC ("/oled/..." messages on the
receive port). External software in any language sends drawing commands;
openFrameworks renders them on the OLED. Double-buffered: build a frame
with /oled/clear ... draw commands ... /oled/show. ScrollText animates in
place; Bitmap blits a packed grayscale image.
*/

#pragma once

#include "ofMain.h"
#include "BaseScreen.h"
#include <vector>
#include <string>

class RemoteScreen : public BaseScreen{
	public:
		enum class Op { Text, Line, Rect, Circle, Pixel, Bar, ScrollText, Bitmap };

		struct Cmd{
			Op op;
			float a = 0, b = 0, c = 0, d = 0, e = 0;  // numeric params
			std::string s;                            // text payload
			std::vector<unsigned char> blob;          // bitmap: grayscale w*h
			float phase = 0;                          // scrolltext animation state
		};

		// Begin accumulating a new (pending) frame.
		void beginFrame();
		// Append a draw command to the pending frame.
		void addCmd(const Cmd &cmd);
		// Commit the pending frame so it becomes what draw() renders.
		void showFrame();

		void draw(float elapsed) override;

	private:
		std::vector<Cmd> pending;
		std::vector<Cmd> active;
		ofTexture bmpTex;  // reused scratch texture for bitmap blits
};
