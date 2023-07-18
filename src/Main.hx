package ;

import js.Browser;
import openfl.display.Bitmap;
import openfl.display.BitmapData;
import openfl.display.Graphics;
import openfl.display.Loader;
import openfl.display.Shape;
import openfl.display.SimpleButton;
import openfl.display.Sprite;
import openfl.display.StageDisplayState;
import openfl.display.DisplayObject;
import openfl.errors.Error;
import openfl.events.Event;
import openfl.events.IOErrorEvent;
import openfl.events.MouseEvent;
import openfl.events.TimerEvent;
import openfl.events.KeyboardEvent;
import openfl.net.URLRequest;
import openfl.system.Security;
import openfl.text.TextField;
import openfl.utils.Timer;
import openfl.geom.Matrix;
import openfl.geom.Rectangle;
import openfl.Lib;
import openfl.utils.ByteArray;
import openfl.display.StageScaleMode;
import openfl.display.GradientType;
import openfl.Vector;
import Manager;
import DataLoader;
import openfl.media.Sound;
import openfl.external.ExternalInterface;
import VideoData;
import js.Lib as JsLib;
import js.html.Screen;
import js.Syntax;

enum ScrollingState { scrollNone; scrollHor; scrollVer; }

typedef SliderHandles = {
	var slw : Float;
	var slh : Float;
	var sx : Float;
	var sy : Float;
}

class Main
{
	var man : Manager;
	var bitmap:Bitmap;
	var bitmap_data:BitmapData;
	var start_time:Float;
	var start_pos : Float;
	var playing : Bool;
	var first_shown : Bool;
	var seeking : Bool;
	var load_timer : Timer;
	//var kf_show_timer : Timer;
	var timer_play : Timer;
	var audio_started : Bool;
	var skipping_stills : Bool;
	var was_playing_bss : Bool; //was playing before skipping stills
	var auto_skip : Bool; // skip idle frames automatically
	var zoom_index : Int = 0;
	var zoom_names : Array<String>;
	var zoom_factors : Array<Float>;
	var scrolling : ScrollingState;

	var tseek0 : Float; // for speed measuring

	var ctrl_alpha : Int; //0..100
	var ctrl_alpha_target : Int;

	//interface
	var text_pos : TextField;
	var loaded_bar : Shape;
	var seek_bar_bg : Shape;
	var slider : Shape;
	var controls : Sprite;
	var text_bg : DisplayObject;
	var start_btn : Sprite;
	var thumb_loader : Loader;
	var worker_shape : Shape;
	var top_sprite : Sprite;

	var btn_home : DisplayObject;
	var btn_prevkey : DisplayObject;
	var btn_prevframe : DisplayObject;
	var btn_play : DisplayObject;
	var btn_pause : DisplayObject;
	var btn_nextkey : DisplayObject;
	var btn_nextframe : DisplayObject;
	var btn_fullscreen : DisplayObject;
	var btn_autoskip : DisplayObject;

	var btn_zoomin : DisplayObject;
	var btn_zoomout : DisplayObject;
	var btn_zoomfit : DisplayObject;
	var zoom_bg : DisplayObject;
	var zoom_text : TextField;
	var hor_slider : Shape;
	var ver_slider : Sprite;
	var hor_view_pos : Float = 0.5; // 0..1, center of view
	var ver_view_pos : Float = 0.5;
	var slider_touch_place : Float; //screen coord where mouse down occured
	var scroll_start_pos : Float; // 0..1

	//interface params
	var width :Int;
	var height : Int;
	var left_corner : Int;
	var panel_top : Int;
	var bar_rect : Rectangle;
	var hor_slider_rect : Rectangle;
	var ver_slider_rect : Rectangle;
	static var buttons_url : String;
	static var buttons_cachekey : String;
	static var button_width = 40;
	static var button_height = 40;
	static var color_button_bg : UInt = 0x404040;
	static var color_button_face : UInt = 0xffffff;
	static var color_button_bg_hover : UInt = 0x00a0ff;
	static var color_loaded_bar : UInt = 0x909090;
	static var color_text : UInt = 0xffffff;
	static var color_frame : UInt = 0xf0f0f0;
	static var button_level : Int = 20;

	static var g_main : Main;
	static var another_video : String;
	var instance_id : String;
	var savedWidth : Int; // stage size before going full screen
	var savedHeight : Int;

	static function main()
	{
		g_main = new Main();
	}

	static function load_another(fname:String)
	{
		another_video = fname;
		g_main = new Main();
	}

	public function new()
	{
		man = new Manager(8);
		instance_id = "not_loaded_yet";
		start_pos = 0;
		playing = false;
		first_shown = false;
		seeking = false;
		left_corner = 50;
		panel_top = 725;
		audio_started = false;
		skipping_stills = false;
		was_playing_bss = false;
		auto_skip = false;
		load_timer = new Timer(40,25);
		load_timer.addEventListener(TimerEvent.TIMER, on_load_timer);
		var me = this;
		scrolling = scrollNone;

		load_timer.start();
		text_pos = new TextField();
		ctrl_alpha = 100; ctrl_alpha_target = 100;

		bar_rect = new Rectangle(15, 700, 600, 8);
		zoom_names = [ "Fit", "100%", "200%" ];
		zoom_factors = [0, 1, 2];
		tseek0 = -1;
	}

	function StopAndClean():Void
	{
		load_timer.stop();
		timer_play.stop();

		if (ExternalInterface.available) {
			ExternalInterface.addCallback("spplay", null);
			ExternalInterface.addCallback("sppause", null);
			ExternalInterface.addCallback("spposition", null);
			ExternalInterface.addCallback("spseek", null);
			ExternalInterface.addCallback("spload", null);
		}

		man.StopAndClean();

		Lib.current.stage.removeEventListener(MouseEvent.CLICK, on_click);
		Lib.current.stage.removeEventListener(MouseEvent.MOUSE_MOVE, on_mouse_move);
		Lib.current.stage.removeEventListener(MouseEvent.MOUSE_DOWN, on_mouse_down);
		Lib.current.stage.removeEventListener(MouseEvent.MOUSE_UP, on_mouse_up);
		Lib.current.stage.removeEventListener(KeyboardEvent.KEY_DOWN, on_key_down);

		while (Lib.current.numChildren > 0)
			Lib.current.removeChildAt(0);
	}

	function color_of_string(s:String, defval:UInt):UInt
	{
		if (s == null) return defval;
		var x = Std.parseInt("0x" + s);
		return x == null ? defval : x;
	}

	function full_path(url: String, fname : String):String
	{
		if (fname == null) return null;
		if (fname.substr(0, 4).toLowerCase() != "http") {
			if (fname.charAt(0)=='/') //path from root
				return url.substr(0, url.indexOf('/', 8)) + fname;
			else
				return url.substr(0, url.lastIndexOf('/') + 1) + fname; //same folder
		}
		return fname;
	}

	function check_full_screen():Bool
	{
		return true;
	}

	function on_load_timer(e:TimerEvent):Void
	{
		if ( Lib.current.stage != null )    {
			Lib.current.stage.scaleMode = StageScaleMode.NO_SCALE;
            if ( Std.isOfType( Lib.current.stage.stageWidth , Int ) )
			{
				trace("Lib.current.loaderInfo.parameters=" + Lib.current.loaderInfo.parameters);
				var url = Lib.current.stage.loaderInfo.url;

				var flashVars : Dynamic<String> = Lib.current.loaderInfo.parameters;
				var fname = flashVars.fname;
				instance_id = flashVars.id != null ? flashVars.id : "player";

				if (fname != null) {
					load_timer.stop();
					var fullscr = check_full_screen();
					if (another_video != null)
						fname = another_video;
					fname = full_path(url, fname);

					color_button_bg = color_of_string(flashVars.buttonbg, color_button_bg);
					color_button_bg_hover = color_of_string(flashVars.buttonhover, color_button_bg_hover);
					color_button_face = color_of_string(flashVars.buttonface, color_button_face);
					color_frame = color_of_string(flashVars.frame, color_frame);
					color_loaded_bar = color_of_string(flashVars.loaded, color_loaded_bar);
					color_text = color_of_string(flashVars.textcolor, color_text);

					buttons_url = flashVars.buttons;
					buttons_cachekey = flashVars.cachekey;
					init_controls(fullscr);

					Lib.current.stage.addEventListener(Event.RESIZE, on_stage_resize);

					#if indexed
					var buffer_size = flashVars.buffer;
					if (buffer_size != null) {
						var sz = Std.parseInt(buffer_size);
						if (sz > 0 && sz < 1024)
							DataLoaderAVIIndexed.storage_limit = sz * 1000000;
					}
					#end

					#if wait
					var thumb = flashVars.thumb;
					if (thumb != null && another_video == null) {
						load_thumbnail(full_path(url, thumb));
						var me = this;
						draw_start_btn(function():Void { me.man.Open(fname, me.on_open); } );
					} else
						man.Open(fname, on_open);
					#else
					man.Open(fname, on_open);
					#end
				}
			}
         }
	}

	function fit(a : Float, mn : Float, mx : Float):Float {
		if (a < mn) return mn;
		if (a > mx) return mx;
		return a;
	}

	function on_stage_resize(event:Event):Void
	{
		var width:Int = Lib.current.stage.stageWidth;
		var height:Int = Lib.current.stage.stageHeight;
		var button_level = 20;
		Logging.MLog("on_stage_resize w="+ width+ " h=" + height);
		panel_top = Std.int(Math.max(height - 78, 0));
		bar_rect.right = width - 30;
		bar_rect.y = panel_top + 5;
		controls.y = panel_top;
		controls.x = 0;
		place_buttons(width, height);

		var vx = bitmap_data.width;
		var vy = bitmap_data.height;
		var kx = width / vx, ky = height / vy;
		var k = Math.min(kx, ky);
		var dx : Float = 0;
		var dy : Float = 0;

		if (zoom_index > 0) {
			k = zoom_factors[zoom_index];
			dx = vx * k * hor_view_pos - width / 2;
			dx = fit(dx, 0, vx * k - width);

			dy = vy * k * (1 - ver_view_pos) - height / 2;
			dy = fit(dy, 0, vy * k - height);
		}

		//Logging.MLog("vx="+vx+" vy="+vy+" k="+k);
		var mat = new Matrix(1.0 * k, 0, 0, -1.0 * k, -dx, height + dy);
		bitmap.transform.matrix = mat;

		zoom_text.text = zoom_names[zoom_index];
		zoom_text.x = zoom_bg.x + zoom_bg.width / 2 - zoom_text.textWidth / 2;

		top_sprite.width = width;
		top_sprite.height = height;

		var d = 5;
		seek_bar_bg.graphics.clear();
		seek_bar_bg.graphics.beginFill(color_button_bg);
		seek_bar_bg.graphics.drawRoundRect(bar_rect.x-d, 0, 2*d+bar_rect.width, bar_rect.height+d*2, 3, 3);
		seek_bar_bg.graphics.endFill();
		seek_bar_bg.graphics.lineStyle(1, color_frame);
		seek_bar_bg.graphics.drawRect(bar_rect.x - 1, d - 1, bar_rect.width + 1, bar_rect.height + 1);

		redraw_sliders(width, height);
	}

	private function calc_slider_handles(width:Float, height:Float) : SliderHandles
	{
		var bigW = bitmap.width;
		var bigH = bitmap.height;
		var w = width - 20; // width of 100% bar in pixels
		var h = height - 20;
		var slw = width * w / bigW; // width of view bar in pixels
		var sx = hor_view_pos * w - slw / 2;
		if (sx < 0) {
			sx = 0;
			hor_view_pos = slw / 2 / w;
		}
		if (sx + slw > w) {
			sx = w - slw;
			hor_view_pos  = (w - slw / 2) / w;
		}

		var slh = height * h / bigH;
		var sy = ver_view_pos * h - slh / 2;
		if (sy < 0) {
			sy = 0;
			ver_view_pos = slh / 2 / h;
		}
		if (sy + slh > h) {
			sy = h - slh;
			ver_view_pos = (h - slh / 2) / h;
		}
		return { slw : slw, slh : slh, sx : sx, sy : sy };
	}

	private function redraw_sliders(width:Float, height:Float) : Void
	{
		//Logging.MLog("redraw_sliders");
		if (zoom_index == 0) {
			hor_slider.visible = false;
			ver_slider.visible = false;
			return;
		}
		var hs = calc_slider_handles(width, height);
		var w = width - 20; // width of 100% bar in pixels
		var h = height - 20;

		hor_slider.graphics.clear();
		hor_slider.graphics.beginFill(color_button_bg);
		hor_slider.graphics.drawRect(0, 0, w, 12);
		hor_slider.graphics.endFill();

		hor_slider.graphics.beginFill(color_loaded_bar);
		hor_slider.graphics.drawRect(hs.sx, 0, hs.slw, 12);
		hor_slider.graphics.endFill();

		ver_slider.graphics.clear();
		ver_slider.graphics.beginFill(color_button_bg);
		ver_slider.graphics.drawRect(0, 0, 12, h);
		ver_slider.graphics.endFill();

		ver_slider.graphics.beginFill(color_loaded_bar);
		ver_slider.graphics.drawRect(0, hs.sy, 12, hs.slh);
		ver_slider.graphics.endFill();

		hor_slider.visible = true;
		ver_slider.visible = true;
		ver_slider.x = width - 12; ver_slider.y = -controls.y;
		hor_slider.width = w; hor_slider.height = 12;
		hor_slider_rect = hor_slider.getBounds(Lib.current.stage);
		ver_slider_rect = ver_slider.getBounds(Lib.current.stage);
	}

	#if wait
	function load_thumbnail(thumb_url:String):Void
	{
		thumb_loader = new Loader();
		thumb_loader.contentLoaderInfo.addEventListener(Event.COMPLETE, on_thumb_loaded);
		thumb_loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, on_thumb_error);
		var req = new URLRequest(thumb_url);
		thumb_loader.load(req);
		Lib.current.addChild(thumb_loader);
	}

	function on_thumb_loaded(e:Event):Void
	{
		var width:Int = Lib.current.stage.stageWidth;
		var height:Int = Lib.current.stage.stageHeight;
		var bmp = cast(thumb_loader.content, Bitmap);
		bmp.scaleX = width / bmp.width;
		bmp.scaleY = height / bmp.height;
		bmp.smoothing = true;
	}
	#end

	function on_thumb_error(e:Event):Void
	{
		trace("failed to load thumbnail image");
	}

	function draw_start_btn(on_start_clicked : Void->Void):Void
	{
		var width:Int = Lib.current.stage.stageWidth;
		var height:Int = Lib.current.stage.stageHeight;

		var d = height > 400 ? 200 : height / 2;
		var x0 = width / 2 - d/2;
		var y0 = height / 2 - d/2;

		start_btn = new Sprite();
		start_btn.graphics.beginFill(0, 0);
		start_btn.graphics.drawRect(0, 0, width, height);
		start_btn.graphics.endFill();
		var matr = new Matrix();
		matr.createGradientBox(height / 2, height / 2, 90, x0, y0);
		start_btn.graphics.beginGradientFill(GradientType.LINEAR, [0xFFFFFF, 0x808080], [1.0, 1.0], [0, 255], matr);
		start_btn.graphics.drawCircle(width / 2, height / 2, d/2);
		start_btn.graphics.endFill();
		start_btn.graphics.beginFill(0x202020, 1.0);
		start_btn.graphics.moveTo(0.4 * d + x0, 0.28 * d + y0);
		start_btn.graphics.lineTo(0.4 * d + x0, 0.73 * d + y0);
		start_btn.graphics.lineTo(0.7 * d + x0, 0.5 * d + y0);
		start_btn.graphics.endFill();
		start_btn.alpha = 0.8;
		var me = this;
		start_btn.addEventListener(MouseEvent.CLICK, function(e:Event):Void {
			if (me.start_btn != null) me.start_btn.visible = false;
			on_start_clicked();
		});
		Lib.current.addChild(start_btn);
	}

	/*function on_show_keyframes(e:TimerEvent):Void ///
	{
		return;
		var kfs = man.GetKeyFrames();
		key_frames_shape.graphics.clear();
		key_frames_shape.graphics.beginFill(0xffff00);
		var bar_length = bar_rect.width;
		for (n in kfs) {
			var x = man.TimeToFraction( man.FrameTime(n) ) * bar_length;
			key_frames_shape.graphics.drawRoundRect(x, 0, 2, 10, 2, 2);
		}
		key_frames_shape.graphics.endFill();
	}*/

	static function make_btn_shape(fname : String, bgcolor : UInt, draw : Graphics -> Void, ?over : Void -> DisplayObject):DisplayObject
	{
		var shape = new Sprite();
		shape.graphics.clear();
		shape.graphics.beginFill(bgcolor);
		shape.graphics.drawRoundRect(0, 0, button_width, button_height, 5, 5);
		shape.graphics.endFill();
		draw(shape.graphics);
		if (over != null)
			shape.addChild(over());
		return shape;
	}

	function make_button_face(fname : String, bgcolor : UInt, draw : Graphics -> Void, ?over : Void -> DisplayObject):DisplayObject
	{
		if (buttons_url != null) {
			var obj = new Sprite();
			var ld = new Loader();
			obj.addChild(ld);
			ld.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
				var shp = make_btn_shape(fname, bgcolor, draw, over);
				obj.addChild(shp);
			});
			var cachekey = buttons_cachekey != null ? "?" + buttons_cachekey : "";
			ld.load(new URLRequest(buttons_url + fname + ".png" + cachekey));
			return obj;
		} else return make_btn_shape(fname, bgcolor, draw, over);
	}

	function create_button(fname: String, draw : Graphics -> Void, ?over : Void -> DisplayObject):DisplayObject
	{
		var up = make_button_face(fname, color_button_bg, draw, over);
		var over = make_button_face(fname + "_h", color_button_bg_hover, draw, over);
		return new SimpleButton(up, over, up, up);
	}

	function init_controls(fullscr : Bool):Void
	{
		var width:Int = Lib.current.stage.stageWidth;
		var height:Int = Lib.current.stage.stageHeight;
		panel_top = height - 78;

		controls = new Sprite();
		controls.x = 0;
		controls.y = panel_top;

		bar_rect.y = panel_top + 5;
		bar_rect.right = width - 30;

		btn_play = create_button("btn_play", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.lineStyle(1, color_button_face);
			g.moveTo(10, 10);
			g.lineTo(10, 30);
			g.lineTo(30, 20);
			g.endFill();
		});
		btn_play.x = 10;
		btn_play.y = button_level;
		controls.addChild(btn_play);

		btn_pause = create_button("btn_pause", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.drawRect(10, 10, 6, 20);
			g.drawRect(23, 10, 6, 20);
			g.endFill();
		});
		btn_pause.x = 60; btn_pause.y = button_level;
		controls.addChild(btn_pause);

		btn_home = create_button("btn_begin", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.drawRect(7, 10, 6, 20);
			g.moveTo(30, 10);
			g.lineTo(30, 30);
			g.lineTo(16, 20);
			g.endFill();
		});
		btn_home.x = 110; btn_home.y = button_level;
		controls.addChild(btn_home);

		btn_prevframe = create_button("btn_prevframe", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.drawRect(27, 10, 6, 20);
			g.moveTo(20, 10);
			g.lineTo(20, 30);
			g.lineTo( 6, 20);
			g.endFill();
		});
		btn_prevframe.x = 160; btn_prevframe.y = button_level;
		controls.addChild(btn_prevframe);

		btn_nextframe = create_button("btn_nextframe", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.drawRect(7, 10, 6, 20);
			g.moveTo(20, 10);
			g.lineTo(20, 30);
			g.lineTo(34, 20);
			g.endFill();
		});
		btn_nextframe.x = 210; btn_nextframe.y = button_level;
		controls.addChild(btn_nextframe);

		btn_prevkey = create_button("btn_prevkey", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.moveTo(18, 10);
			g.lineTo(18, 30);
			g.lineTo( 4, 20);
			g.moveTo(34, 10);
			g.lineTo(34, 30);
			g.lineTo( 20, 20);
			g.endFill();
		});
		btn_prevkey.x = 260; btn_prevkey.y = button_level;
		controls.addChild(btn_prevkey);

		btn_nextkey = create_button("btn_nextkey", function(g : Graphics):Void {
			g.beginFill(color_button_face, 1.0);
			g.moveTo(22, 10);
			g.lineTo(22, 30);
			g.lineTo(36, 20);
			g.moveTo( 6, 10);
			g.lineTo( 6, 30);
			g.lineTo(20, 20);
			g.endFill();
		});
		btn_nextkey.x = 310; btn_nextkey.y = button_level;
		controls.addChild(btn_nextkey);

		btn_zoomout = create_button("btn_zoomout", function(g : Graphics):Void {
			g.lineStyle(2, color_button_face);
			g.drawRect(10, 19, 20, 2);
		});
		btn_zoomout.x = 500; btn_zoomout.y = button_level;
		controls.addChild(btn_zoomout);

		btn_zoomin = create_button("btn_zoomin", function(g : Graphics):Void {
			g.lineStyle(2, color_button_face);
			g.drawRect(10, 19, 20, 2);
			g.drawRect(19, 10, 2, 20);
		});
		btn_zoomin.x = 550; btn_zoomin.y = button_level;
		controls.addChild(btn_zoomin);

		btn_zoomfit = create_button("btn_zoomfit", function(g : Graphics):Void {
			g.lineStyle(2, color_button_face);
			g.drawRect(8, 10, 6, 1);
			g.drawRect(7, 11, 1, 5);
			g.drawRect(8+24-5, 10, 5, 1);
			g.drawRect(8+24, 11, 1, 5);

			g.drawRect(8, 30, 6, 1);
			g.drawRect(7, 24, 1, 6);
			g.drawRect(8+24-5, 30, 5, 1);
			g.drawRect(8+24, 24, 1, 6);
		});
		btn_zoomfit.x = 600; btn_zoomfit.y = button_level;
		controls.addChild(btn_zoomfit);

		var zoom_bg_shp = new Shape();
		zoom_bg_shp.graphics.beginFill(color_button_bg);
		zoom_bg_shp.graphics.drawRoundRect(0, 0, 40, 28, 5, 5);
		zoom_bg_shp.graphics.endFill();
		zoom_bg = zoom_bg_shp;
		zoom_bg.x = 650; zoom_bg.y = button_level + 6;
		zoom_bg.width = 40;
		controls.addChild(zoom_bg);

		zoom_text = new TextField();
		zoom_text.text = "Fit";
		zoom_text.x =zoom_bg.x + 25 - zoom_text.textWidth / 2;
		zoom_text.y = button_level + 10;
		zoom_text.selectable = false;
		zoom_text.textColor = color_text;
		zoom_text.width = 40;
		controls.addChild(zoom_text);

		if (fullscr) {
			btn_fullscreen = create_button("btn_fullscreen", function(g:Graphics):Void {
				g.lineStyle(2, color_button_face);
				g.drawRect(8, 10, 24, 1);
				g.drawRect(8, 10, 1, 20);
				g.drawRect(8, 30, 25, 1);
				g.drawRect(8+24, 10, 1, 20);
			});
			btn_fullscreen.x = 400; btn_fullscreen.y = button_level;
			controls.addChild(btn_fullscreen);
		}

		#if msvc // not really related to msvc, but both autoskip feature and msvc are for one customer
		btn_autoskip = mk_btn_autoskip(auto_skip);
		btn_autoskip.x = 450; btn_autoskip.y = button_level;
		controls.addChild(btn_autoskip);
		#end

		var mk_timecode_shape = function():Shape {
			var shp = new Shape();
			shp.graphics.beginFill(color_button_bg);
			shp.graphics.drawRoundRect(0, 0, 100, 28, 5, 5);
			shp.graphics.endFill();
			return shp;
		}

		if (buttons_url != null) {
			var obj = new Sprite();
			var ld = new Loader();
			obj.addChild(ld);
			ld.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):Void {
				obj.addChild(mk_timecode_shape());
			});
			var cachekey = buttons_cachekey != null ? "?" + buttons_cachekey : "";
			ld.load(new URLRequest(buttons_url + "btn_timecode.png" + cachekey));
			text_bg = obj;
		} else
			text_bg = mk_timecode_shape();

		text_bg.x = 360;
		text_bg.y = button_level + 6;
		controls.addChild(text_bg);

		text_pos.text = "00:00 / 00:00";
		text_pos.textColor = color_text;
		text_pos.x = 360 + 50 - text_pos.textWidth / 2;
		text_pos.y = button_level + 10;
		text_pos.selectable = false;
		controls.addChild(text_pos);

		btn_home.addEventListener(MouseEvent.CLICK, on_home);
		btn_nextframe.addEventListener(MouseEvent.CLICK, on_nextframe);
		btn_nextkey.addEventListener(MouseEvent.CLICK, on_nextkey);
		btn_pause.addEventListener(MouseEvent.CLICK, on_pause);
		btn_play.addEventListener(MouseEvent.CLICK, on_play);
		btn_prevframe.addEventListener(MouseEvent.CLICK, on_prevframe);
		btn_prevkey.addEventListener(MouseEvent.CLICK, on_prevkey);
		#if msvc
		btn_autoskip.addEventListener(MouseEvent.CLICK, on_autoskip);
		#end
		if (btn_fullscreen != null) btn_fullscreen.addEventListener(MouseEvent.CLICK, on_fullscreen);
		btn_zoomin.addEventListener(MouseEvent.CLICK, on_zoomin);
		btn_zoomout.addEventListener(MouseEvent.CLICK, on_zoomout);
		btn_zoomfit.addEventListener(MouseEvent.CLICK, on_zoomfit);
	}

	function mk_btn_autoskip(checked : Bool) : DisplayObject
	{
		var name = checked ? "btn_skip_on" : "btn_skip_off";
		return create_button(name, function(g:Graphics):Void {
				g.lineStyle(1, color_button_face);
				g.drawRect(2, 16, 8, 8);
				if (checked) {
					g.moveTo(4, 20);
					g.lineTo(6, 24);
					g.lineTo(10, 16);
				}
			}, function():DisplayObject {
				var txt_skipstills = new TextField();
				txt_skipstills.text = "Skip\n idle";
				txt_skipstills.textColor = color_text;
				txt_skipstills.x = 11;
				txt_skipstills.y = 4;
				txt_skipstills.selectable = false;
				return txt_skipstills;
			});
	}

	function on_home(e:MouseEvent):Void
	{
		/*#if logging
		Logging.extra = true;
		DataLoader.JSLog("extra logging off");
		Logging.extra = false;
		text_pos.text = "off";
		#else*/
		seek_start(0);
		//#end
	}

	function on_nextframe(e:MouseEvent):Void
	{
		//load_another("VirtualDub.avi");
		//js.Lib.debug();
		if (ExternalInterface.available && ExternalInterface.call(
			"(function(x) { if (typeof on_next_btn == \"function\") on_next_btn(x); })", instance_id) != null)
				return;
		seek_start(man.NextFrameTime());
	}

	function on_nextkey(e:MouseEvent):Void
	{
		seek_start(man.NextKeyTime());
	}

	function on_pause(e:MouseEvent):Void
	{
		playing = false;
		man.audio_track.Stop();
		btn_pause.visible = false;
		btn_play.visible = true;
		skipping_stills = false;
	}

	function on_play(e:MouseEvent):Void
	{
		start_time = haxe.Timer.stamp();
		start_pos = man.shown_time;
		playing = true;
		audio_started = false;
		btn_pause.visible = true;
		btn_play.visible = false;
		skipping_stills = false;
	}

	function on_prevframe(e:MouseEvent):Void
	{
		/*#if logging
		var nextra = !Logging.extra;
		Logging.extra = true;
		var state = nextra ? "on" : "off";
		DataLoader.JSLog("extra logging " + state);
		Logging.extra = nextra;
		text_pos.text = state;
		#else*/
		seek_start(man.PrevFrameTime());
		//#end
	}

	function on_prevkey(e:MouseEvent):Void
	{
		seek_start(man.PrevKeyTime());
	}

	function isFullScreen() : Bool
	{
		var doc = Browser.document;
		if (untyped js.Syntax.code('"webkitFullscreenEnabled" in doc'))
		untyped 	return doc.webkitIsFullScreen;
		if (untyped js.Syntax.code('"fullscreenEnabled" in doc')) {
			untyped var fe = doc.fullscreenElement;
			return fe != null;
		} else
		if (untyped js.Syntax.code('"msFullscreenElement" in doc')) {
			untyped var fe = doc.msFullscreenElement;
			return fe != null;
		} else
		if (untyped js.Syntax.code('"mozFullScreenElement" in doc')) {
			untyped var fe = doc.mozFullScreenElement;
			return fe != null;
		}
		return false;
	}

	function fullScreenChanged() {
		Logging.MLog("fullScreenChanged");
		if (!isFullScreen()) {
			if (savedWidth > 0)
				resizePlayer(savedWidth, savedHeight);
		}
	}

	function fullScreenOn():Void
	{
		var doc = Browser.document;
		var element = doc.getElementById(instance_id);
		if (untyped js.Syntax.code('"requestFullscreen" in element')) {
			doc.addEventListener("fullscreenchange", fullScreenChanged);
			untyped element.requestFullscreen();
		} else
		if (untyped js.Syntax.code('"webkitRequestFullscreen" in element')) {
			doc.addEventListener("webkitfullscreenchange", fullScreenChanged);
			untyped element.webkitRequestFullscreen();
		} else
		if (untyped js.Syntax.code('"mozRequestFullScreen" in element')) {
			doc.addEventListener("mozfullscreenchange", fullScreenChanged);
			untyped element.mozRequestFullScreen();
		} else
		if (untyped js.Syntax.code('"msRequestFullscreen" in element')) {
			doc.addEventListener("MSFullscreenChange", fullScreenChanged);
			untyped element.msRequestFullscreen();
		}
	}

	function fullScreenOff():Void
	{
		var doc = Browser.document;
		if (untyped js.Syntax.code('"exitFullscreen" in doc')) {
			untyped doc.exitFullscreen();
		} else
		if (untyped js.Syntax.code('"webkitExitFullscreen" in doc')) {
			untyped doc.webkitExitFullscreen();
		} else
		if (untyped js.Syntax.code('"mozCancelFullScreen" in doc')) {
			untyped doc.mozCancelFullScreen();
		} else
		if (untyped js.Syntax.code('"msExitFullscreen" in doc')) {
			untyped doc.msExitFullscreen();
		}
	}

	function on_fullscreen(e:MouseEvent):Void
	{
		Logging.MLog("on_fullscreen, id="+ instance_id);
		if (isFullScreen()) {
			fullScreenOff();
			//if (savedWidth > 0)
			//	resizePlayer(savedWidth, savedHeight);
		} else {
			savedWidth = Lib.current.stage.stageWidth;
			savedHeight = Lib.current.stage.stageHeight;
			fullScreenOn();
			var s : Screen = untyped window.screen;
			resizePlayer(s.width, s.height);
		}
	}

	function on_autoskip(e:MouseEvent):Void
	{
		auto_skip = !auto_skip;
		controls.removeChild(btn_autoskip);
		btn_autoskip = mk_btn_autoskip(auto_skip);
		btn_autoskip.y = button_level;
		controls.addChild(btn_autoskip);
		var width:Int = Lib.current.stage.stageWidth;
		var height:Int = Lib.current.stage.stageHeight;
		place_buttons(width, height);
		btn_autoskip.addEventListener(MouseEvent.CLICK, on_autoskip);
	}

	function place_buttons(width:Int, height:Int):Void
	{
		var left = width >= 600 ? width / 2 - 300 + 5 :
				  (width >= 460 ? width - 455 : 5);
		//width / 2 - 150 + 450 = w/2 + 300
		btn_home.x = left;
		btn_prevkey.x = left + 50 * 1;
		btn_prevframe.x = left + 50 * 2;
		btn_play.x = left + 50 * 3;
		btn_pause.x = left + 50 * 3;
		btn_pause.visible = playing;
		btn_play.visible = !playing;
		btn_nextframe.x = left + 50 * 4;
		btn_nextkey.x = left + 50 * 5;
		text_bg.x = left + 50 * 6;
		text_pos.x = left + 50 * 6 + 50 - text_pos.textWidth/2;

		var z = text_bg.x + 140;

		btn_zoomout.x = z + 0;
		btn_zoomin.x = z + 50;

		zoom_bg.x = z + 100;
		zoom_text.x = z + 120 - zoom_text.textWidth / 2;
		if (btn_fullscreen != null) { btn_fullscreen.x = z + 200; }
		btn_zoomfit.x = z + 150;
		#if msvc
		btn_autoskip.x = z + 250;
		#end
	}

	private function on_open(v:VideoInfo):Void
	{
		width = v.X; height = v.Y;
		var st_width : Float = Lib.current.stage.stageWidth;
		var st_height: Float = Lib.current.stage.stageHeight;

		bitmap_data = new BitmapData(v.X, v.Y, false);
		bitmap = new Bitmap(bitmap_data);
		Logging.MLog("on_open st_width=" + st_width + " st_height=" + st_height + " v.X=" + v.X + " v.Y=" + v.Y);
		var mat = new Matrix(st_width / v.X, 0, 0, -st_height/v.Y, 0, st_height);
		bitmap.transform.matrix = mat;
		bitmap.smoothing = true;

		if (thumb_loader != null) thumb_loader.visible = false;
		Lib.current.addChild(bitmap);
		Lib.current.stage.addEventListener(MouseEvent.CLICK, on_click);
		Lib.current.stage.addEventListener(MouseEvent.MOUSE_MOVE, on_mouse_move);
		Lib.current.stage.addEventListener(MouseEvent.MOUSE_DOWN, on_mouse_down);
		Lib.current.stage.addEventListener(MouseEvent.MOUSE_UP, on_mouse_up);
		Lib.current.stage.addEventListener(KeyboardEvent.KEY_DOWN, on_key_down);

		//if (width < 450) width = 450;
		//if (height < 64) height = 64;

		panel_top = Std.int(Math.max(st_height - 78, 0));
		bar_rect.right = st_width - 30;
		bar_rect.y = panel_top + 5;
		controls.y = panel_top;

		var d = 5;
		seek_bar_bg = new Shape();
		seek_bar_bg.graphics.beginFill(color_button_bg);
		seek_bar_bg.graphics.drawRoundRect(bar_rect.x-d, 0, 2*d+bar_rect.width, bar_rect.height+d*2, 3, 3);
		seek_bar_bg.graphics.endFill();
		seek_bar_bg.graphics.lineStyle(1, color_frame);
		seek_bar_bg.graphics.drawRect(bar_rect.x-1, d-1, bar_rect.width+1, bar_rect.height+1);
		seek_bar_bg.x = 0; seek_bar_bg.y = 0;
		controls.addChild(seek_bar_bg);

		loaded_bar = new Shape();
		loaded_bar.graphics.beginFill(color_loaded_bar);
		loaded_bar.graphics.drawRect(0,0, 100, bar_rect.height);
		loaded_bar.graphics.endFill();
		loaded_bar.x = bar_rect.x; loaded_bar.y = d;
		controls.addChild(loaded_bar);

		ver_slider = new Sprite();
		hor_slider = new Shape();
		redraw_sliders(st_width, st_height);
		hor_slider.x = 0; hor_slider.y = 64;
		ver_slider.x = st_width - 12; ver_slider.y = -controls.y;
		controls.addChild(hor_slider);
		controls.addChild(ver_slider);

		worker_shape = new Shape();
		worker_shape.graphics.beginFill(0x000080);
		//worker_shape.graphics.drawRoundRect(0, 0, 3, 8, 2, 2);
		worker_shape.graphics.drawCircle(0, bar_rect.height / 2, 3);
		worker_shape.graphics.endFill();
		worker_shape.x = bar_rect.x;// left_corner;
		worker_shape.y = d;// panel_top + 10;
		controls.addChild(worker_shape);

		slider = new Shape();
		var mat = new Matrix();
		var rad = 6;
		var grey = 0xd0d0d0;
		mat.createGradientBox(rad*2, rad*2, 0, -rad, -rad);
		slider.graphics.beginGradientFill(GradientType.RADIAL, [grey, grey, 0xffffff, grey], [1,1,1,1], [0, 150, 200, 255], mat);
		slider.graphics.drawCircle(0, 0, rad);
		slider.graphics.endFill();
		slider.x = bar_rect.x;
		slider.y = d + bar_rect.height / 2;
		controls.addChild(slider);

		top_sprite = new Sprite();
		top_sprite.graphics.beginFill(0, 0);
		top_sprite.graphics.drawRect(0, 0, width, height);
		top_sprite.graphics.endFill();
		//top_sprite.width = width; top_sprite.height = height;
		top_sprite.addEventListener(MouseEvent.MOUSE_OVER, on_mouse_over);
		top_sprite.addEventListener(MouseEvent.MOUSE_OUT, on_mouse_out);
		Lib.current.addChild(top_sprite);

		place_buttons(Std.int(st_width), Std.int(st_height));
		Lib.current.addChild(controls);
		controls.addEventListener(MouseEvent.MOUSE_OVER, on_ctrl_mouse_over);

		if (ExternalInterface.available) {
			ExternalInterface.addCallback("spplay", js_play);
			ExternalInterface.addCallback("sppause", js_pause);
			ExternalInterface.addCallback("spposition", js_position);
			ExternalInterface.addCallback("spseek", js_seek);
			ExternalInterface.addCallback("spload", js_load);
			ExternalInterface.addCallback("spnextchange", js_nextdifferent);

			ExternalInterface.addCallback("spresize", js_resize);
		}

		start_time = haxe.Timer.stamp();
		timer_play = new Timer(50, 0);
		timer_play.addEventListener(TimerEvent.TIMER, play_timer);
		timer_play.start();
		on_stage_resize(null);

		#if logging
		/*var timer_elog = new Timer(1000);
		timer_elog.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):Void {
			if (ExternalInterface.available) {
				var msg = Logging.FlushLog();
				if (msg != "") ExternalInterface.call("playerLog", msg);
			}
          } );
		timer_elog.start();*/
		#end
	}

	function strtime(t:Float, show_hour : Bool):String
	{
		var hour = Std.int(t / 3600);
		var min = Std.int((t - hour * 3600) / 60);
		var sec = Std.int(t - hour * 3600 - min * 60);
		var to_s = function(x:Int):String {
			var s = Std.string(x);
			return s.length > 1 ? s : "0" + s;
		}
		return (show_hour ? Std.string(hour) + ":" : "") + to_s(min) + ":" + to_s(sec);
	}

	private function play_timer(e:TimerEvent):Void
	{
		try {
		if (skipping_stills) {
			var t = man.SkipStills(false);
			if (t != null) {
				seeking = man.SeekTo(t, seek_done, bitmap_data);
				if (was_playing_bss)
					on_play(null);
				skipping_stills = false;
			}
		}
		var time = haxe.Timer.stamp() - start_time + start_pos;
		if (playing) {
			if (!seeking && !skipping_stills) {
				var res = man.GetDecompressedFrame(time, bitmap_data, true);
				var do_pause = time >= man.LoadedAudioTime(), do_skip = false;
				switch(res) {
					case notsoon: do_pause = true;
					case decompressed(changes):
						if (auto_skip && changes != null && !changes)
							do_skip = true;
					case soon:
				}
				if (do_pause) on_pause(null);
				else if (do_skip) skipping_stills = true;
			}
		} else
		if (!first_shown) {
			switch(man.GetDecompressedFrame(0, bitmap_data, false)) {
				case decompressed(_), soon :
					first_shown = true;
					haxe.Timer.delay(function() {
						ExternalInterface.call(
							"(function(a,b,c) { if (typeof on_player_loaded == \"function\") on_player_loaded(a,b,c); })",
							instance_id, width, height);
					}, 10);
				case notsoon:
			}
		}

		if (playing && !seeking && !audio_started && !skipping_stills)
			audio_started = man.audio_track.Play(time);

		var shtime = man.shown_time;
		var bar_length = bar_rect.width;
		var left_corner = bar_rect.left;
		slider.x = left_corner + bar_length * man.TimeToFraction(shtime);
		loaded_bar.x = bar_rect.x + bar_length * man.LoadedFractionStart();
		loaded_bar.width = bar_length * (man.LoadedFractionEnd() - man.LoadedFractionStart());
		if (seeking || skipping_stills) {
			worker_shape.x = left_corner + bar_length * man.WorkerPos();
			worker_shape.visible = true;
		} else
			worker_shape.visible = false;

		var total_time = man.TotalTime();
		var show_hour = total_time > 3600;
		text_pos.text = strtime(shtime, show_hour) + " / " + strtime(total_time, show_hour);
		text_pos.x = text_bg.x + 50 - text_pos.textWidth/2;

		if (ctrl_alpha != ctrl_alpha_target) {
			if (ctrl_alpha_target > ctrl_alpha)
				ctrl_alpha += 20;
			else
				ctrl_alpha -= 20;
			controls.alpha = ctrl_alpha / 100;
		}
		} catch (ex:openfl.errors.Error) { Logging.MLog("internal error3 " + ex + ";" + ex.getStackTrace()); }
		  catch (ex:Dynamic) { Logging.MLog("internal error4 " + ex); }
	}

	function on_mouse_down(e:MouseEvent):Void
	{
		scrolling = try_scroll(e);
	}
	function on_mouse_up(e:MouseEvent):Void
	{
		scrolling = scrollNone;
	}

	function on_mouse_move(e:MouseEvent):Void
	{
		switch(scrolling) {
			case scrollHor:
				if (e.stageX >= hor_slider_rect.left && e.stageX < hor_slider_rect.right) {
					var p = (e.stageX - slider_touch_place) / hor_slider_rect.width + scroll_start_pos;
					scroll(true, fit(p, 0.0, 1.0));
				}
			case scrollVer:
				if (e.stageY >= ver_slider_rect.top && e.stageY < ver_slider_rect.bottom) {
					var p = (e.stageY - slider_touch_place) / ver_slider_rect.height + scroll_start_pos;
					scroll(false, fit(p, 0.0, 1.0));
				}
			case scrollNone:
		}
	}

	function try_scroll(e:MouseEvent):ScrollingState
	{
		if (hor_slider_rect == null) return scrollNone;
		if (hor_slider_rect.contains(e.stageX, e.stageY)) {
			var hs = calc_slider_handles(Lib.current.stage.stageWidth,	Lib.current.stage.stageHeight);
			slider_touch_place = e.stageX;
			if (!(e.stageX >= hs.sx && e.stageX < hs.sx + hs.slw))
				scroll(true, (e.stageX - hor_slider_rect.left) / hor_slider_rect.width);
			scroll_start_pos = hor_view_pos;
			return scrollHor;
		}
		if (ver_slider_rect.contains(e.stageX, e.stageY))  {
			var hs = calc_slider_handles(Lib.current.stage.stageWidth,	Lib.current.stage.stageHeight);
			slider_touch_place = e.stageY;
			if (!(e.stageY >= hs.sy && e.stageY < hs.sy + hs.slh))
				scroll(false, (e.stageY - ver_slider_rect.top) / ver_slider_rect.height);
			scroll_start_pos = ver_view_pos;
			return scrollVer;
		}
		return scrollNone;
	}

	function on_key_down(e:KeyboardEvent):Void
	{
		if (zoom_index == 0) return;
		switch(e.keyCode) {
			case 37: scroll(true, fit(hor_view_pos - 0.1, 0, 1)); //left
			case 38: scroll(false, fit(ver_view_pos - 0.1, 0, 1));//up
			case 39: scroll(true, fit(hor_view_pos + 0.1, 0, 1));//right
			case 40: scroll(false, fit(ver_view_pos + 0.1, 0, 1));//down
		}
	}

	function on_click(e:MouseEvent):Void
	{
		scrolling = scrollNone;
		var bar_length = bar_rect.width;
		var left_corner = bar_rect.left;
		if (e.stageX >= left_corner && e.stageX <= left_corner + bar_length &&
			e.stageY >= panel_top && e.stageY <= panel_top + 20) {
				var prc = (e.stageX - left_corner) / bar_length;
				var t = man.FractionToTime(prc);
				seek_start(t);
		}
	}

	function seek_start(time:Float):Void
	{
		skipping_stills = false;
		tseek0 = Browser.window.performance.now();
		man.audio_track.Stop();
		seeking = man.SeekTo(time, seek_done, bitmap_data);
	}

	function seek_done():Void
	{
		if (tseek0 > 0) {
			var t = Browser.window.performance.now();
			var msg = "seek done in t=" + (t - tseek0);
			trace(msg);
			//untyped playerLog(msg);
			tseek0 = -1;
		}
		seeking = false;
		start_time = haxe.Timer.stamp();
		start_pos = man.shown_time;
		if (playing)
			audio_started = false;
	}

	function scroll(hor : Bool, pos : Float):Void // pos in 0..1
	{
		if (hor) hor_view_pos = pos;
		else	 ver_view_pos = pos;
		on_stage_resize(null);
	}

	function on_mouse_over(e:MouseEvent):Void
	{
		ctrl_alpha_target = 100;
	}

	function on_mouse_out(e:MouseEvent):Void
	{
		ctrl_alpha_target = 0;
		scrolling = scrollNone;
	}

	function on_ctrl_mouse_over(e:MouseEvent):Void
	{
		ctrl_alpha = 80; ctrl_alpha_target = 100;
	}

	function on_zoomin(e:MouseEvent):Void
	{
		if (zoom_index < zoom_names.length - 1) {
			zoom_index++;
			on_stage_resize(null);
		}
	}
	function on_zoomout(e:MouseEvent):Void
	{
		if (zoom_index > 0) {
			zoom_index--;
			on_stage_resize(null);
		}

	}
	function on_zoomfit(e:MouseEvent):Void
	{
		if (zoom_index != 0) {
			zoom_index = 0;
			on_stage_resize(null);
		}
	}

	function js_play():Void
	{
		on_play(null);
	}

	function js_pause():Void
	{
		on_pause(null);
	}

	function js_seek(time:Float):Void
	{
		if (time < 0 || time >= man.TotalTime()) return;
		seek_start(time);
	}

	function js_position():Float
	{
		return man.shown_time;
	}

	function js_load(fname:String):Void
	{
		StopAndClean();
		load_another(fname);
	}

	function js_nextdifferent():Void
	{
		was_playing_bss = playing;
		on_pause(null);
		skipping_stills = true;
		var t = man.SkipStills(true);
		if (t != null) {
			seeking = man.SeekTo(t, seek_done, bitmap_data);
			if (was_playing_bss)
				on_play(null);
			skipping_stills = false;
		}
	}

	function js_resize(x:Int, y:Int):Void
	{
		Logging.MLog("js_resize x=" + x + " y=" + y + " mode=" + Lib.current.stage.scaleMode);
		resizePlayer(x, y);
	}

	function resizePlayer(x:Int, y:Int):Void
	{
		Logging.MLog("resizing to " + x +"x" + y);
		untyped var player = document.getElementById(instance_id);
		untyped var s = player.childNodes[0]; //the stage div
		untyped s.style.width  = x+"px";
		untyped s.style.height = y+"px";
		Lib.current.stage.window.resize(x, y);

		// How to fix it? Same problem in internet: https://community.openfl.org/t/openfl-display-stage-has-no-field-onwindowresize/11670
		//Lib.current.stage.onWindowResize(Lib.current.stage.window, x, y);
	}
}