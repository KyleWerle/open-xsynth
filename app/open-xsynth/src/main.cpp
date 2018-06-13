#include "ofMain.h"
#include "ofApp.h"

//========================================================================
int main( ){

	ofSetupOpenGL(128, 64, OF_WINDOW);			// <-------- setup the GL context

	ofRunApp( new ofApp());

}
