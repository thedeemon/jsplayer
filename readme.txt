An in-browser decoder and player for videos made with ScreenPressor codec.
Supports AVI files with video streams made by ScreenPressor 2, 3, and 4.

https://infognition.com/ScreenPressor/player_js.html

Originally written in Haxe and compiled to Flash, later changed to be compiled to JavaScript using OpenFL framework. 

As of July 2023 'master' branch contains a version that can be built with modern versions of Haxe and OpenFL, however the result loads CPU & GPU too much even when on pause because of some OpenFL glitch forcing it to update the page elements constantly. There are some issues with resizing and fullscreen mode too.
If built without -Ddom flag there's no such CPU/GPU load however there are more issues with scaling and unexpected animations. 

To build a version where everything works well, one can use Haxe 3 and an older version of OpenFL, the code targeting Haxe 3 and build instructions can be found in the branch 'haxe3' here, not 'master'.
