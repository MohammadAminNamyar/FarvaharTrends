package org.farvahartrends.platform;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import io.flutter.plugin.common.MethodChannel;

/** User-selected documents only. Private keys leave the app only encrypted. */
final class ChannelDocuments {
  private final Context context;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private MethodChannel.Result pending;
  private String contents;
  private int operation;
  private static final int SAVE=4820, OPEN=4821, IMAGE=4822;
  ChannelDocuments(Context context) { this.context=context; }
  void start(Activity activity,String method,String name,String text,MethodChannel.Result result) {
    if (activity==null) { result.error("document_unavailable","Open the app to select a document.",null); return; }
    if (pending!=null) { result.error("document_busy","A document picker is already open.",null); return; }
    int op=method.equals("saveChannelDocument") ? SAVE : method.equals("pickNewsImage") ? IMAGE : OPEN;
    if (op==SAVE && (text==null || text.getBytes(StandardCharsets.UTF_8).length>128*1024)) { result.error("document_size","Document is too large.",null); return; }
    Intent intent=new Intent(op==SAVE ? Intent.ACTION_CREATE_DOCUMENT : Intent.ACTION_OPEN_DOCUMENT);
    intent.addCategory(Intent.CATEGORY_OPENABLE);
    intent.setType(op==IMAGE ? "image/*" : op==SAVE ? "application/json" : "*/*");
    if (op==SAVE) intent.putExtra(Intent.EXTRA_TITLE,name!=null && name.matches("[A-Za-z0-9._-]{1,100}") ? name : "FarvaharTrends-channel.json");
    pending=result; contents=text; operation=op;
    try { activity.startActivityForResult(intent,op); }
    catch (RuntimeException e) { finish(result,null,"Document picker is unavailable."); }
  }
  boolean onResult(int request,int resultCode,Intent data) {
    if (request!=SAVE && request!=OPEN && request!=IMAGE) return false;
    final MethodChannel.Result callback=pending;
    final String text=contents;
    if (callback==null || request!=operation) return true;
    if (resultCode!=Activity.RESULT_OK || data==null || data.getData()==null) { finish(callback,null,null); return true; }
    final Uri uri=data.getData();
    if (!"content".equals(uri.getScheme())) { finish(callback,null,"Select a document from the system picker."); return true; }
    worker.execute(()->{
      Object output=null; String error=null;
      try {
        if (request==SAVE) {
          try (OutputStream stream=context.getContentResolver().openOutputStream(uri,"wt")) {
            if (stream==null) throw new IllegalStateException();
            stream.write(text.getBytes(StandardCharsets.UTF_8)); stream.flush(); output=Boolean.TRUE;
          }
        } else {
          byte[] bytes;
          try (InputStream stream=context.getContentResolver().openInputStream(uri)) {
            if (stream==null) throw new IllegalStateException();
            bytes=readBounded(stream,request==IMAGE ? 10*1024*1024 : 128*1024);
          }
          if (request==IMAGE) output=compress(bytes);
          else output=StandardCharsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString();
        }
      } catch (Exception | OutOfMemoryError e) { error=request==IMAGE ? "Choose an image smaller than 10 MB and 64 megapixels." : "The selected document could not be read or saved."; }
      final Object value=output; final String failure=error;
      main.post(()->finish(callback,value,failure));
    });
    return true;
  }
  private static byte[] readBounded(InputStream input,int limit) throws Exception {
    ByteArrayOutputStream out=new ByteArrayOutputStream(); byte[] buffer=new byte[8192]; int read;
    while ((read=input.read(buffer))!=-1) { if (out.size()+read>limit) throw new IllegalArgumentException(); out.write(buffer,0,read); }
    return out.toByteArray();
  }
  private static byte[] compress(byte[] input) throws Exception {
    BitmapFactory.Options options=new BitmapFactory.Options(); options.inJustDecodeBounds=true;
    BitmapFactory.decodeByteArray(input,0,input.length,options);
    if (options.outWidth<1 || options.outHeight<1 || (long)options.outWidth*options.outHeight>64000000L) throw new IllegalArgumentException();
    options.inJustDecodeBounds=false; options.inSampleSize=1;
    while (Math.max(options.outWidth,options.outHeight)/options.inSampleSize>2560) options.inSampleSize*=2;
    Bitmap bitmap=BitmapFactory.decodeByteArray(input,0,input.length,options);
    if (bitmap==null) throw new IllegalArgumentException();
    try {
      int orientation=1;
      try { orientation=new ExifInterface(new ByteArrayInputStream(input)).getAttributeInt(ExifInterface.TAG_ORIENTATION,1); } catch (Exception ignored) {}
      Matrix transform=new Matrix();
      switch (orientation) {
        case 2: transform.setScale(-1,1); break;
        case 3: transform.setRotate(180); break;
        case 4: transform.setScale(1,-1); break;
        case 5: transform.setRotate(90); transform.postScale(-1,1); break;
        case 6: transform.setRotate(90); break;
        case 7: transform.setRotate(270); transform.postScale(-1,1); break;
        case 8: transform.setRotate(270); break;
      }
      if (!transform.isIdentity()) { Bitmap rotated=Bitmap.createBitmap(bitmap,0,0,bitmap.getWidth(),bitmap.getHeight(),transform,true); if(rotated!=bitmap) { bitmap.recycle(); bitmap=rotated; } }
      int largest=Math.max(bitmap.getWidth(),bitmap.getHeight());
      if (largest>1280) { Bitmap scaled=Bitmap.createScaledBitmap(bitmap,Math.max(1,bitmap.getWidth()*1280/largest),Math.max(1,bitmap.getHeight()*1280/largest),true); if(scaled!=bitmap) {bitmap.recycle();bitmap=scaled;} }
      for (int attempt=0;attempt<6;attempt++) {
        ByteArrayOutputStream out=new ByteArrayOutputStream();
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG,Math.max(40,75-attempt*8),out)) throw new IllegalArgumentException();
        if (out.size()<=96*1024) return out.toByteArray();
        if (attempt>=2) { Bitmap smaller=Bitmap.createScaledBitmap(bitmap,Math.max(1,bitmap.getWidth()*3/4),Math.max(1,bitmap.getHeight()*3/4),true); if(smaller!=bitmap){bitmap.recycle();bitmap=smaller;} }
      }
      throw new IllegalArgumentException();
    } finally { bitmap.recycle(); }
  }
  private void finish(MethodChannel.Result callback,Object value,String error) {
    if (pending!=callback) return;
    pending=null; contents=null;
    if (error==null) callback.success(value); else callback.error("channel_document",error,null);
  }
  void cancel() { if(pending!=null) finish(pending,null,null); }
  void close() { cancel(); worker.shutdownNow(); }
}
