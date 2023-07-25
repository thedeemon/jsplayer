An in-browser decoder and player for videos made with ScreenPressor codec.
Supports AVI files with video streams made by ScreenPressor 2, 3, and 4.

https://infognition.com/ScreenPressor/player_js.html

Originally written in Haxe and compiled to Flash, later changed to be compiled to JavaScript using OpenFL framework. 
Active development happened around 2017 and the player works best when built with versions of tools from that time:

Haxe 3, OpenFL 5.0.0 and Lime 4.1.0.

To build this version, install Haxe 3.4.7 (last version before Haxe 4), make sure 'haxe' and 'haxelib' are in your PATH, and HAXE_STD_PATH env variable is set properly, then

haxelib install lime 4.1.0
haxelib install openfl 5.0.0

then the actual build command is

openfl build html5 -Ddom -Dwait -minify  

An optional build flag -Dmsvc adds support for MSVideo1 codec too.

When built with -Dwait flag it loads a thumbnail for the video and doesn't request actual video until the big play button is pressed. Without this option the player starts loading the video immediately.

The -Ddom flag makes it use browser DOM elements instead of WebGL. -Ddom worked great with OpenFL 5.
As of July 2023 modern version of OpenFL with this flag produces a result that works but loads CPU and GPU constantly even when video is paused, this didn't happen with OpenFL 5, hence this branch.
Without -Ddom modern OpenFL produces a result that doesn't create such CPU/GPU load, but there are issues with scaling and unexpected animations. I guess these can be fixed but it requires time and effort I don't have right now.
