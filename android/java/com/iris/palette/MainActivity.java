package com.iris.palette;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ContentValues;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.util.Log;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Base64;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.Map;

/**
 * Iris 调色盘 —— 原生外壳。
 *
 * 页面本身是移动优先的单文件 WebGL 编辑器，这里不重写界面，只补齐它拿不到的原生能力：
 * 系统相册/文件选择、流式落盘到媒体库、系统分享、返回键语义、状态栏配色、字体缩放隔离。
 */
public class MainActivity extends Activity {

    private static final String TAG = "IrisSave";

    private static final String HOST = "iris.local";              /* 虚拟域名，请求全部由本地资源接管 */
    private static final String START_URL = "https://" + HOST + "/index.html";
    private static final int REQ_FILE = 2001;

    private static final int INK = 0xFF08080A;
    private static final int CARD_BG = 0xF21A1A1E;
    private static final int ACCENT = 0xFFE3B65C;
    private static final int TXT = 0xFFF3F3F5;
    private static final int SUB = 0xFF85858E;

    private WebView web;
    private FrameLayout root;
    private ValueCallback<Uri[]> pendingPicker;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Handler cardTimer = new Handler(Looper.getMainLooper());
    private View savedCard;
    private long lastBackAt = 0L;
    private boolean usedFileFallback = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().setStatusBarColor(INK);
        getWindow().setNavigationBarColor(INK);

        root = new FrameLayout(this);
        root.setBackgroundColor(INK);

        web = new WebView(this);
        web.setBackgroundColor(INK);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(false);
        s.setTextZoom(100);                       /* 隔离系统字体放大，避免布局被撑坏 */
        s.setAllowFileAccess(false);              /* 页面走 https 虚拟源，不需要裸文件访问 */
        s.setAllowContentAccess(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        disableAutoDarkening(s);

        web.setWebViewClient(new Client());
        web.setWebChromeClient(new Chrome());
        web.addJavascriptInterface(new IrisBridge(), "IrisNative");

        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);

        if (savedInstanceState != null) {
            web.restoreState(savedInstanceState);
        } else {
            web.loadUrl(START_URL);
        }
    }

    /** 只有用户想拿走的成品才允许落盘：图片、视频、打包、配置。 */
    private static boolean allowedMime(String m) {
        if (m == null) return false;
        if (m.startsWith("image/") || m.startsWith("video/")) return true;
        if (m.equals("application/zip") || m.equals("application/x-zip-compressed")) return true;
        if (m.equals("application/json") || m.equals("text/plain")) return true;
        return false;
    }

    /** 有些 ROM 的 WebView 会对深色页面做「算法压暗」，把自家配色二次压暗，必须关掉。 */
    private void disableAutoDarkening(WebSettings s) {
        try {
            if (Build.VERSION.SDK_INT >= 29 && Build.VERSION.SDK_INT < 33) {
                s.setForceDark(WebSettings.FORCE_DARK_OFF);
            }
        } catch (Throwable ignored) {
        }
        try {
            WebSettings.class.getMethod("setAlgorithmicDarkeningAllowed", boolean.class)
                    .invoke(s, false);
        } catch (Throwable ignored) {
        }
        try {
            WebSettings.class.getMethod("setForceDark", int.class).invoke(s, 0);
        } catch (Throwable ignored) {
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        if (web != null) web.saveState(outState);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (web != null) web.onResume();
    }

    @Override
    protected void onPause() {
        if (web != null) web.onPause();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        cardTimer.removeCallbacksAndMessages(null);
        if (savedCard != null && root != null) root.removeView(savedCard);
        if (web != null) {
            web.setWebChromeClient(null);
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }

    /* ================= 返回键：先让页面自己收浮层，收不动才走退出语义 ================= */

    @Override
    public void onBackPressed() {
        if (web == null) {
            super.onBackPressed();
            return;
        }
        web.evaluateJavascript("(function(){try{return window.__irisBack?window.__irisBack():false}catch(e){return false}})()",
                value -> {
                    if ("true".equals(value)) return;       /* 页面收起了某个浮层/子页，吃掉这次返回 */
                    if (web != null && web.canGoBack()) {
                        web.goBack();
                        return;
                    }
                    long now = System.currentTimeMillis();
                    if (now - lastBackAt < 1600L) {
                        MainActivity.super.onBackPressed();
                    } else {
                        lastBackAt = now;
                        toast("再按一次退出 Iris");
                    }
                });
    }

    /* ================= 文件选择（照片 / 视频 / HEIC / LUT / JSON 都走这里） ================= */

    private class Chrome extends WebChromeClient {
        @Override
        public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback,
                                         FileChooserParams params) {
            if (pendingPicker != null) {
                pendingPicker.onReceiveValue(null);
                pendingPicker = null;
            }
            pendingPicker = callback;
            Intent intent = buildPickerIntent(params);
            try {
                startActivityForResult(intent, REQ_FILE);
                return true;
            } catch (Throwable t) {
                pendingPicker = null;
                toast("系统里没有可用的文件选择器");
                return false;
            }
        }
    }

    /**
     * 页面 accept 里混着 image/*、video/*、.heic、.cube 这类写法。直接拿 accept 当 MIME 过滤，
     * 系统选择器会把 .cube / .heic 这类识别不出的文件藏起来，所以这里自己展开成 MIME 再决定是否放宽。
     */
    private Intent buildPickerIntent(WebChromeClient.FileChooserParams params) {
        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);

        java.util.LinkedHashSet<String> mimes = new java.util.LinkedHashSet<>();
        boolean hasUnknownExt = false;

        String[] accepts = params != null ? params.getAcceptTypes() : null;
        if (accepts != null) {
            for (String raw : accepts) {
                if (raw == null) continue;
                for (String token : raw.split(",")) {
                    String a = token.trim().toLowerCase(java.util.Locale.US);
                    if (a.isEmpty()) continue;
                    if (a.startsWith(".")) {
                        String mapped = extToMime(a);
                        if (mapped == null) hasUnknownExt = true; else mimes.add(mapped);
                    } else if (a.contains("/")) {
                        mimes.add(a);
                    }
                }
            }
        }

        if (hasUnknownExt || mimes.isEmpty()) {
            intent.setType("*/*");            /* 有认不出的扩展名时不做 MIME 过滤，保证能选到文件 */
        } else if (mimes.size() == 1) {
            intent.setType(mimes.iterator().next());
        } else {
            intent.setType("*/*");
            intent.putExtra(Intent.EXTRA_MIME_TYPES, mimes.toArray(new String[0]));
        }

        if (params != null && params.getMode() == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE) {
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);   /* 实况照片要能同时选 HEIC + MOV */
        }
        return intent;
    }

    private static String extToMime(String ext) {
        switch (ext) {
            case ".jpg": case ".jpeg": return "image/jpeg";
            case ".png": return "image/png";
            case ".webp": return "image/webp";
            case ".gif": return "image/gif";
            case ".heic": case ".heif": return "image/heic";
            case ".mp4": return "video/mp4";
            case ".m4v": return "video/x-m4v";
            case ".mov": return "video/quicktime";
            case ".json": return "application/json";
            default: return null;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQ_FILE) {
            if (pendingPicker == null) return;
            Uri[] result = null;
            if (resultCode == RESULT_OK && data != null) {
                if (data.getClipData() != null) {
                    int n = data.getClipData().getItemCount();
                    result = new Uri[n];
                    for (int i = 0; i < n; i++) result[i] = data.getClipData().getItemAt(i).getUri();
                } else if (data.getData() != null) {
                    result = new Uri[]{data.getData()};
                }
            }
            pendingPicker.onReceiveValue(result);
            pendingPicker = null;
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    /* ================= 虚拟 https 源：把 assets 当网站托管，保住 secure context ================= */

    private static String mimeOf(String name) {
        String n = name.toLowerCase();
        if (n.endsWith(".html") || n.endsWith(".htm")) return "text/html";
        if (n.endsWith(".js")) return "application/javascript";
        if (n.endsWith(".css")) return "text/css";
        if (n.endsWith(".json")) return "application/json";
        if (n.endsWith(".png")) return "image/png";
        if (n.endsWith(".jpg") || n.endsWith(".jpeg")) return "image/jpeg";
        if (n.endsWith(".svg")) return "image/svg+xml";
        if (n.endsWith(".webp")) return "image/webp";
        if (n.endsWith(".woff2")) return "font/woff2";
        if (n.endsWith(".ttf")) return "font/ttf";
        return "application/octet-stream";
    }

    private WebResourceResponse assetResponse(Uri uri) {
        String path = uri.getPath();
        if (path == null || path.isEmpty() || "/".equals(path)) path = "/index.html";
        String name = path.startsWith("/") ? path.substring(1) : path;
        String mime = mimeOf(name);
        try {
            InputStream in = getAssets().open(name);
            String charset = mime.startsWith("text/") || mime.contains("javascript") || mime.contains("json")
                    ? "utf-8" : null;
            WebResourceResponse r = new WebResourceResponse(mime, charset, in);
            Map<String, String> headers = new HashMap<>();
            headers.put("Cache-Control", "no-store");
            r.setResponseHeaders(headers);
            r.setStatusCodeAndReasonPhrase(200, "OK");
            return r;
        } catch (IOException e) {
            return new WebResourceResponse("text/plain", "utf-8",
                    new ByteArrayInputStream("404".getBytes()));
        }
    }

    private class Client extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri uri = request.getUrl();
            if (uri != null && HOST.equals(uri.getHost())) return assetResponse(uri);
            return null;
        }

        @Override
        @SuppressWarnings("deprecation")
        public WebResourceResponse shouldInterceptRequest(WebView view, String url) {
            Uri uri = Uri.parse(url);
            if (HOST.equals(uri.getHost())) return assetResponse(uri);
            return null;
        }

        @Override
        public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request != null && request.isForMainFrame() && !usedFileFallback) {
                usedFileFallback = true;
                view.getSettings().setAllowFileAccess(true);
                view.loadUrl("file:///android_asset/index.html");
            }
        }

        @Override
        public void onPageFinished(WebView view, String url) {
            injectShim(view);
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            Uri uri = request.getUrl();
            if (uri == null) return false;
            String scheme = uri.getScheme() == null ? "" : uri.getScheme();
            if ("https".equals(scheme) && HOST.equals(uri.getHost())) return false;
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, uri));
            } catch (Exception e) {
                toast("没有能打开这个链接的应用");
            }
            return true;
        }
    }

    private void injectShim(WebView view) {
        try {
            InputStream in = getAssets().open("iris-shim.js");
            BufferedReader br = new BufferedReader(new InputStreamReader(in, "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) sb.append(line).append('\n');
            br.close();
            view.evaluateJavascript(sb.toString(), null);
        } catch (IOException ignored) {
        }
    }

    /* ================= 落盘：JS 分块传字节，这里按 MIME 写进对应媒体库 ================= */

    public class IrisBridge {

        private OutputStream os;
        private Uri targetUri;
        private File targetFile;
        private String name = "iris.bin";
        private String mime = "application/octet-stream";
        private long bytes;

        @JavascriptInterface
        public synchronized void start(String encodedName, String mimeIn) {
            closeAndDiscard();

            try { name = Uri.decode(encodedName); } catch (Throwable ignored) { }
            if (name == null || name.trim().isEmpty()) name = "Iris_" + System.currentTimeMillis();
            name = name.replace('/', '_').replace('\\', '_');
            mime = (mimeIn == null || mimeIn.isEmpty()) ? "application/octet-stream" : mimeIn;
            bytes = 0;

            /* 第二道闸：只接受真正会被用户看见的作品类型。
               任何非图片/视频/打包/配置文件一律拒绝，避免把页面内部的临时资源写进相册。 */
            if (!allowedMime(mime)) {
                Log.i(TAG, "save rejected, mime=" + mime + " name=" + name);
                mime = null;
                return;
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    boolean image = mime.startsWith("image/");
                    boolean video = mime.startsWith("video/");
                    Uri collection = video ? MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                            : image ? MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                            : MediaStore.Downloads.EXTERNAL_CONTENT_URI;
                    String rel = video ? Environment.DIRECTORY_MOVIES + "/Iris"
                            : image ? Environment.DIRECTORY_PICTURES + "/Iris"
                            : Environment.DIRECTORY_DOWNLOADS + "/Iris";

                    ContentValues cv = new ContentValues();
                    cv.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
                    cv.put(MediaStore.MediaColumns.MIME_TYPE, mime);
                    cv.put(MediaStore.MediaColumns.RELATIVE_PATH, rel);
                    cv.put(MediaStore.MediaColumns.IS_PENDING, 1);
                    targetUri = getContentResolver().insert(collection, cv);
                    if (targetUri != null) os = getContentResolver().openOutputStream(targetUri, "w");
                } catch (Throwable ignored) {
                }
            }

            if (os == null) {   /* Android 9 及以下，或媒体库插入失败：退回应用私有目录 + 扫描入库 */
                try {
                    File base = mime.startsWith("video/")
                            ? getExternalFilesDir(Environment.DIRECTORY_MOVIES)
                            : mime.startsWith("image/")
                            ? getExternalFilesDir(Environment.DIRECTORY_PICTURES)
                            : getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS);
                    File dir = new File(base != null ? base : getFilesDir(), "Iris");
                    if (!dir.exists()) dir.mkdirs();
                    targetFile = new File(dir, name);
                    os = new FileOutputStream(targetFile);
                } catch (Throwable t) {
                    os = null;
                    toast("保存失败：存储不可写");
                }
            }
        }

        @JavascriptInterface
        public synchronized void append(String chunk) {
            if (os == null || chunk == null) return;
            try {
                byte[] data = Base64.decode(chunk, Base64.DEFAULT);
                os.write(data);
                bytes += data.length;
            } catch (Throwable ignored) {
            }
        }

        @JavascriptInterface
        public synchronized void finish() {
            if (os == null) return;
            try { os.flush(); } catch (Throwable ignored) { }
            try { os.close(); } catch (Throwable ignored) { }
            os = null;

            final String fName = name;
            final String fMime = mime;
            final long fBytes = bytes;
            final Uri outUri = targetUri;
            final File outFile = targetFile;
            targetUri = null;
            targetFile = null;

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                if (outUri != null) {
                    try {
                        ContentValues cv = new ContentValues();
                        cv.put(MediaStore.MediaColumns.IS_PENDING, 0);
                        getContentResolver().update(outUri, cv, null, null);
                    } catch (Throwable ignored) { }
                }
                ui.post(() -> onSaved(fName, fMime, outUri, fBytes));
                return;
            }

            if (outFile == null) return;
            if (outFile.length() <= 0) {
                outFile.delete();
                return;
            }
            if (isMedia(fMime)) {
                MediaScannerConnection.scanFile(MainActivity.this,
                        new String[]{outFile.getAbsolutePath()}, new String[]{fMime},
                        (path, scanned) -> ui.post(() -> onSaved(fName, fMime, scanned, fBytes)));
            } else {
                ui.post(() -> onSaved(fName, fMime, null, fBytes));
            }
        }

        @JavascriptInterface
        public synchronized void abort() {
            closeAndDiscard();
        }

        private void closeAndDiscard() {
            try { if (os != null) os.close(); } catch (Throwable ignored) { }
            os = null;
            if (targetUri != null) {
                try { getContentResolver().delete(targetUri, null, null); } catch (Throwable ignored) { }
                targetUri = null;
            }
            if (targetFile != null) {
                try { targetFile.delete(); } catch (Throwable ignored) { }
                targetFile = null;
            }
        }
    }

    private static boolean isMedia(String mime) {
        return mime != null && (mime.startsWith("image/") || mime.startsWith("video/"));
    }

    /* ================= 保存完成后的原生小卡片（分享 / 打开） ================= */

    private void onSaved(String name, String mime, Uri uri, long bytes) {
        if (isFinishing() || isDestroyed()) return;
        if (web != null) web.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS);
        showSavedCard(name, mime, uri, bytes);
    }

    private void showSavedCard(final String name, final String mime, final Uri uri, final long bytes) {
        if (root == null) return;
        cardTimer.removeCallbacksAndMessages(null);
        if (savedCard != null) {
            root.removeView(savedCard);
            savedCard = null;
        }

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setPadding(dp(12), dp(10), dp(6), dp(10));

        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD_BG);
        bg.setCornerRadius(dp(18));
        bg.setStroke(dp(1), 0x33FFFFFF);
        card.setBackground(bg);
        card.setElevation(dp(12));

        Bitmap thumb = loadThumb(uri, dp(56));
        if (thumb != null) {
            ImageView iv = new ImageView(this);
            iv.setImageBitmap(thumb);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            GradientDrawable round = new GradientDrawable();
            round.setColor(0xFF24242A);
            round.setCornerRadius(dp(10));
            iv.setBackground(round);
            iv.setClipToOutline(true);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(44), dp(44));
            lp.rightMargin = dp(10);
            card.addView(iv, lp);
        }

        LinearLayout texts = new LinearLayout(this);
        texts.setOrientation(LinearLayout.VERTICAL);
        TextView t1 = new TextView(this);
        t1.setText(uri != null ? "已保存到相册 · Iris" : "已保存 · Iris");
        t1.setTextColor(TXT);
        t1.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
        t1.setTypeface(t1.getTypeface(), android.graphics.Typeface.BOLD);
        TextView t2 = new TextView(this);
        t2.setText(shortName(name) + "  ·  " + sizeText(bytes));
        t2.setTextColor(SUB);
        t2.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f);
        t2.setSingleLine(true);
        t2.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        texts.addView(t1);
        texts.addView(t2);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        card.addView(texts, tlp);

        if (uri != null) {
            TextView share = new TextView(this);
            share.setText("分享");
            share.setTextColor(ACCENT);
            share.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
            share.setPadding(dp(10), dp(8), dp(10), dp(8));
            share.setOnClickListener(v -> {
                hideCard();
                shareUri(name, mime, uri);
            });
            card.addView(share);
            card.setOnClickListener(v -> {
                hideCard();
                openUri(mime, uri);
            });
        }

        TextView close = new TextView(this);
        close.setText("✕");
        close.setTextColor(SUB);
        close.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
        close.setPadding(dp(10), dp(8), dp(10), dp(8));
        close.setOnClickListener(v -> hideCard());
        card.addView(close);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM;
        lp.setMargins(dp(12), 0, dp(12), dp(18));
        card.setLayoutParams(lp);
        card.setAlpha(0f);
        card.setTranslationY(dp(26));

        root.addView(card);
        savedCard = card;
        card.animate().alpha(1f).translationY(0f).setDuration(220).start();

        cardTimer.postDelayed(this::hideCard, 7000);
    }

    private void hideCard() {
        final View card = savedCard;
        savedCard = null;
        if (card == null || root == null) return;
        card.animate().alpha(0f).translationY(dp(26)).setDuration(180)
                .withEndAction(() -> root.removeView(card)).start();
    }

    private void shareUri(String name, String mime, Uri uri) {
        try {
            Intent send = new Intent(Intent.ACTION_SEND);
            send.setType(mime == null ? "*/*" : mime);
            send.putExtra(Intent.EXTRA_STREAM, uri);
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(send, "分享 " + shortName(name)));
        } catch (Throwable t) {
            toast("没有可用的分享应用");
        }
    }

    private void openUri(String mime, Uri uri) {
        try {
            Intent view = new Intent(Intent.ACTION_VIEW);
            view.setDataAndType(uri, mime);
            view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(view);
        } catch (Throwable t) {
            toast("没有能打开它的应用");
        }
    }

    private Bitmap loadThumb(Uri uri, int targetPx) {
        if (uri == null || !"content".equals(uri.getScheme())) return null;
        InputStream in = null;
        try {
            in = getContentResolver().openInputStream(uri);
            if (in == null) return null;
            BitmapFactory.Options opts = new BitmapFactory.Options();
            opts.inJustDecodeBounds = true;
            BitmapFactory.decodeStream(in, null, opts);
            in.close();
            if (opts.outWidth <= 0) return null;

            int sample = 1;
            while (opts.outWidth / sample > targetPx * 2) sample *= 2;

            in = getContentResolver().openInputStream(uri);
            BitmapFactory.Options o2 = new BitmapFactory.Options();
            o2.inSampleSize = sample;
            return BitmapFactory.decodeStream(in, null, o2);
        } catch (Throwable t) {
            return null;
        } finally {
            try { if (in != null) in.close(); } catch (Throwable ignored) { }
        }
    }

    private static String shortName(String name) {
        if (name == null) return "";
        return name.length() > 26 ? name.substring(0, 12) + "…" + name.substring(name.length() - 8) : name;
    }

    private static String sizeText(long bytes) {
        if (bytes >= 1024 * 1024) return String.format(java.util.Locale.US, "%.1f MB", bytes / 1048576f);
        if (bytes >= 1024) return String.format(java.util.Locale.US, "%.0f KB", bytes / 1024f);
        return bytes + " B";
    }

    private int dp(float v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private void toast(String msg) {
        ui.post(() -> Toast.makeText(MainActivity.this, msg, Toast.LENGTH_SHORT).show());
    }
}
