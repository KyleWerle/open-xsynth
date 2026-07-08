/*
See RemoteScreen.h. Renders the committed display list each frame.
Monochrome (white on black) into the 128x64 OLED buffer.
*/

#include "RemoteScreen.h"
#include <cmath>


void RemoteScreen::beginFrame(){
	pending.clear();
}

void RemoteScreen::addCmd(const Cmd &cmd){
	pending.push_back(cmd);
}

void RemoteScreen::showFrame(){
	active = pending;
}

void RemoteScreen::draw(float elapsed){
	ofSetColor(255, 255, 255);

	for(Cmd &c : active){
		switch(c.op){
			case Op::Text:
				ofDrawBitmapString(c.s, c.a, c.b);
				break;
			case Op::Line:
				ofSetLineWidth(1);
				ofDrawLine(c.a, c.b, c.c, c.d);
				break;
			case Op::Rect:
				if(c.e > 0.5f){ ofFill(); } else { ofNoFill(); }
				ofDrawRectangle(c.a, c.b, c.c, c.d);
				ofFill();
				break;
			case Op::Circle:
				if(c.d > 0.5f){ ofFill(); } else { ofNoFill(); }
				ofDrawCircle(c.a, c.b, c.c);
				ofFill();
				break;
			case Op::Pixel:
				ofDrawRectangle(c.a, c.b, 1, 1);
				break;
			case Op::Bar:
				ofNoFill();
				ofDrawRectangle(c.a, c.b, c.c, c.d);
				ofFill();
				ofDrawRectangle(c.a, c.b, c.c * ofClamp(c.e, 0.0f, 1.0f), c.d);
				break;
			case Op::ScrollText: {
				// c.b = y, c.e = speed (px/sec); marquee right-to-left.
				c.phase += c.e * elapsed;
				float textW = c.s.size() * 8.0f;
				float span = textW + SCREEN_WIDTH;
				float off = std::fmod(c.phase, span > 0 ? span : 1.0f);
				ofDrawBitmapString(c.s, SCREEN_WIDTH - off, c.b);
				break;
			}
			case Op::Bitmap: {
				int w = static_cast<int>(c.c);
				int h = static_cast<int>(c.d);
				if(w > 0 && h > 0 &&
				   static_cast<int>(c.blob.size()) >= w * h){
					if(!bmpTex.isAllocated() ||
					   bmpTex.getWidth() != w || bmpTex.getHeight() != h){
						bmpTex.allocate(w, h, GL_LUMINANCE);
						bmpTex.setTextureMinMagFilter(GL_NEAREST, GL_NEAREST);
					}
					bmpTex.loadData(c.blob.data(), w, h, GL_LUMINANCE);
					ofSetColor(255, 255, 255);
					bmpTex.draw(c.a, c.b, w, h);
				}
				break;
			}
		}
	}
}
