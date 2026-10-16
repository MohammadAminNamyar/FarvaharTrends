package org.farvahartrends.platform;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.PixelFormat;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.view.View;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

/** GPU-only moving layer. No Flutter frame, Java path rasterization or image upload per tick. */
final class RadarPlatformView implements PlatformView {
  static final class Factory extends PlatformViewFactory {
    private final BinaryMessenger messenger;
    Factory(BinaryMessenger messenger) {
      super(StandardMessageCodec.INSTANCE);
      this.messenger = messenger;
    }
    @Override public PlatformView create(Context context, int id, Object args) {
      return new RadarPlatformView(context, messenger, id, args);
    }
  }

  private final RadarSurface view;
  private final MethodChannel channel;
  RadarPlatformView(Context context, BinaryMessenger messenger, int id, Object args) {
    channel = new MethodChannel(messenger, "farvahartrends/radar/" + id);
    view = new RadarSurface(context, () -> channel.invokeMethod("unavailable", null));
    channel.setMethodCallHandler((call, result) -> {
      if (!"update".equals(call.method)) { result.notImplemented(); return; }
      view.update(call.arguments);
      result.success(null);
    });
    view.update(args);
  }
  @Override public View getView() { return view; }
  @Override public void dispose() {
    channel.setMethodCallHandler(null);
    view.dispose();
  }

  private static final class RadarSurface extends GLSurfaceView {
    private final RadarRenderer renderer;
    private ScheduledExecutorService ticker;
    private boolean animate, disposed, visible = true;

    RadarSurface(Context context, Runnable unavailable) {
      super(context);
      setEGLContextClientVersion(2);
      setEGLConfigChooser(8, 8, 8, 8, 0, 0);
      getHolder().setFormat(PixelFormat.TRANSLUCENT);
      setZOrderMediaOverlay(true);
      setPreserveEGLContextOnPause(true);
      setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
      setFocusable(false);
      setClickable(false);
      renderer = new RadarRenderer(getResources().getDisplayMetrics().density,
          () -> post(() -> { if (!disposed) unavailable.run(); }));
      setRenderer(renderer);
      setRenderMode(RENDERMODE_WHEN_DIRTY);
    }
    void update(Object args) {
      if (disposed || !(args instanceof Map)) return;
      Map<?, ?> state = (Map<?, ?>) args;
      renderer.active = Boolean.TRUE.equals(state.get("active"));
      renderer.searching = Boolean.TRUE.equals(state.get("searching"));
      Object color = state.get("backgroundColor");
      if (color instanceof Number) renderer.backgroundColor = ((Number) color).intValue();
      animate = Boolean.TRUE.equals(state.get("animate"));
      syncMotion();
      requestRender();
    }
    private void syncMotion() {
      if (renderer == null) return; // View can dispatch visibility during construction.
      boolean run = !disposed && renderer.active && animate && visible && isAttachedToWindow()
          && getWindowVisibility() == VISIBLE && isShown() && ValueAnimator.areAnimatorsEnabled();
      if (run == (ticker != null)) return;
      if (run) {
        renderer.resume();
        ticker = Executors.newSingleThreadScheduledExecutor(task -> {
          Thread thread = new Thread(task, "FarvaharRadarClock");
          thread.setDaemon(true);
          return thread;
        });
        // Retain 30 fps and a five-second cycle even on 120 Hz displays.
        ticker.scheduleAtFixedRate(this::requestRender, 0, 33333333, TimeUnit.NANOSECONDS);
      } else stopMotion();
    }
    private void stopMotion() {
      if (ticker != null) { ticker.shutdownNow(); ticker = null; }
      if (renderer != null) renderer.pause();
    }
    @Override protected void onAttachedToWindow() { super.onAttachedToWindow(); syncMotion(); }
    @Override protected void onDetachedFromWindow() { stopMotion(); super.onDetachedFromWindow(); }
    @Override protected void onWindowVisibilityChanged(int visibility) {
      super.onWindowVisibilityChanged(visibility);
      syncMotion();
    }
    @Override public void onVisibilityAggregated(boolean visible) {
      super.onVisibilityAggregated(visible);
      this.visible = visible;
      syncMotion();
    }
    void dispose() { disposed = true; stopMotion(); onPause(); }
  }

  private static final class RadarRenderer implements GLSurfaceView.Renderer {
    private static final String VERTEX =
        "attribute vec2 aPosition; varying vec2 vPosition;"
        + "void main(){vPosition=vec2(aPosition.x,-aPosition.y);gl_Position=vec4(aPosition,0.,1.);}";
    private static final String FRAGMENT =
        "precision highp float; varying vec2 vPosition; uniform vec2 uSize; uniform vec3 uBackground;"
        + "uniform float uPhase; uniform float uDensity; uniform float uSearching;"
        + "void main(){vec2 p=vPosition*uSize*.5; float r=min(uSize.x,uSize.y)*.44;"
        + "float d=length(p); float phase=uPhase;"
        + "float pulse=.4*(1.-phase)*(1.-smoothstep(.75*uDensity-.5,.75*uDensity+.5,abs(d-r*(.3+.7*phase))));"
        + "float angle=mod(atan(p.y,p.x)-phase*6.28318530718+12.56637061436,6.28318530718);"
        + "float sweep=uSearching*.22*clamp(angle/1.57079632679,0.,1.)"
        + "*(1.-smoothstep(r-.5,r+.5,d))"
        + "*(1.-smoothstep(1.57079632679-.5/max(d,1.),1.57079632679+.5/max(d,1.),angle));"
        + "float a=pulse+sweep*(1.-pulse);gl_FragColor=vec4(mix(uBackground,vec3(.094117647,.654901961,.627450980),a),1.);}";
    private final FloatBuffer vertices = ByteBuffer.allocateDirect(32)
        .order(ByteOrder.nativeOrder()).asFloatBuffer();
    private final float density;
    private final Runnable unavailable;
    private int program, phaseLocation, sizeLocation, searchingLocation, backgroundLocation;
    private volatile int backgroundColor;
    private int width, height;
    private volatile boolean active, searching, moving;
    private volatile float stoppedPhase;
    private volatile long started;
    RadarRenderer(float density, Runnable unavailable) {
      this.density = density;
      this.unavailable = unavailable;
      vertices.put(new float[] {-1,-1, 1,-1, -1,1, 1,1}).position(0);
    }
    float phase() {
      return moving ? (float)((stoppedPhase + (System.nanoTime()-started)/5000000000.0)%1.0) : stoppedPhase;
    }
    void resume() { started = System.nanoTime(); moving = true; }
    void pause() { float phase = phase(); moving = false; stoppedPhase = phase; }
    private int shader(int type, String source) {
      int shader = GLES20.glCreateShader(type);
      GLES20.glShaderSource(shader, source);
      GLES20.glCompileShader(shader);
      int[] ok = new int[1];
      GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0);
      if (ok[0] == 0) { GLES20.glDeleteShader(shader); throw new IllegalStateException("Radar shader unavailable"); }
      return shader;
    }
    @Override public void onSurfaceCreated(GL10 unused, EGLConfig config) {
      int vertex = 0, fragment = 0;
      try {
        vertex = shader(GLES20.GL_VERTEX_SHADER, VERTEX);
        fragment = shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT);
        program = GLES20.glCreateProgram();
        GLES20.glAttachShader(program, vertex);
        GLES20.glAttachShader(program, fragment);
        GLES20.glBindAttribLocation(program, 0, "aPosition");
        GLES20.glLinkProgram(program);
        int[] ok = new int[1];
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) throw new IllegalStateException("Radar program unavailable");
        GLES20.glUseProgram(program);
        phaseLocation = GLES20.glGetUniformLocation(program, "uPhase");
        sizeLocation = GLES20.glGetUniformLocation(program, "uSize");
        searchingLocation = GLES20.glGetUniformLocation(program, "uSearching");
        backgroundLocation = GLES20.glGetUniformLocation(program, "uBackground");
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uDensity"), density);
      } catch (RuntimeException error) {
        if (program != 0) GLES20.glDeleteProgram(program);
        program = 0;
        unavailable.run();
      } finally {
        if (vertex != 0) GLES20.glDeleteShader(vertex);
        if (fragment != 0) GLES20.glDeleteShader(fragment);
      }
    }
    @Override public void onSurfaceChanged(GL10 unused, int width, int height) {
      this.width = width; this.height = height;
      GLES20.glViewport(0, 0, width, height);
    }
    @Override public void onDrawFrame(GL10 unused) {
      int background = backgroundColor;
      float red = ((background >> 16) & 255)/255f;
      float green = ((background >> 8) & 255)/255f;
      float blue = (background & 255)/255f;
      // Hybrid composition can retain a previous Flutter image behind this
      // surface. Paint the card background so an old count cannot show through;
      // Flutter paints the current rings and labels above this opaque layer.
      GLES20.glClearColor(red, green, blue, 1);
      GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
      if (program == 0 || !active) return;
      GLES20.glUseProgram(program);
      GLES20.glUniform3f(backgroundLocation, red, green, blue);
      GLES20.glUniform1f(phaseLocation, phase());
      GLES20.glUniform2f(sizeLocation, width, height);
      GLES20.glUniform1f(searchingLocation, searching ? 1 : 0);
      GLES20.glEnableVertexAttribArray(0);
      GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, 0, vertices);
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
    }
  }
}
