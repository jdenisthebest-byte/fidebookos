// FideBookOS 1.25 — Native Material 3 "Liquid Glass & Motion" Settings Screen (libfidebook_visual.so)
// Injected natively into Android Settings -> Display & touch and Settings Homepage via IA_SETTINGS.
// Built 100% offline with Android NDK clang++ (-static-libstdc++).

#include <jni.h>
#include <android/log.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>

#include "../fidebook_logo_rgba.h"

#define LOG_TAG "FideBookVisual"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

enum VisualAction : int {
    VACT_BACK = 1,
    VACT_GLASS_ON = 10,
    VACT_GLASS_OFF = 11,
    VACT_LEVEL_1 = 21,
    VACT_LEVEL_2 = 22,
    VACT_LEVEL_3 = 23,
    VACT_MBLUR_UI = 30,
    VACT_MBLUR_ALL = 31,
    VACT_MBLUR_OFF = 32,
};

struct M3Palette {
    jint bgCanvas;
    jint surfaceShell;
    jint surfaceHero;
    jint surfaceCard;
    jint surfaceCardSelected;
    jint primary;
    jint onPrimary;
    jint secondaryContainer;
    jint onSecondaryContainer;
    jint onSurface;
    jint onSurfaceVariant;
    jint outlineVariant;
    jint rippleOnSurface;
    jint successBg;
    jint successFg;
};

static const M3Palette kDarkPalette = {
    (jint)0xFF0E1117,
    (jint)0xFF151B26,
    (jint)0xFF101722,
    (jint)0xFF1B2331,
    (jint)0xFF1D3254,
    (jint)0xFFA8C7FA,
    (jint)0xFF062E6F,
    (jint)0xFF223047,
    (jint)0xFFD3E3FD,
    (jint)0xFFE6EDF7,
    (jint)0xFF9AA6B8,
    (jint)0xFF2B3547,
    (jint)0x33A8C7FA,
    (jint)0xFF123824,
    (jint)0xFF6DD58C,
};

static const M3Palette kLightPalette = {
    (jint)0xFFF2F5FB,
    (jint)0xFFFFFFFF,
    (jint)0xFFEAF0FB,
    (jint)0xFFF7F9FE,
    (jint)0xFFD3E3FD,
    (jint)0xFF0B57D0,
    (jint)0xFFFFFFFF,
    (jint)0xFFD3E3FD,
    (jint)0xFF041E49,
    (jint)0xFF1B1F26,
    (jint)0xFF475061,
    (jint)0xFFD6DCE8,
    (jint)0x260B57D0,
    (jint)0xFFE6F4EA,
    (jint)0xFF137333,
};

static bool clearIfException(JNIEnv* env, const char* where) {
    if (env->ExceptionCheck()) {
        LOGW("JNI exception cleared in %s", where);
        env->ExceptionClear();
        return true;
    }
    return false;
}

static std::string jstrToUtf8(JNIEnv* env, jstring js) {
    if (!js) return "";
    const char* chars = env->GetStringUTFChars(js, nullptr);
    if (!chars) return "";
    std::string out(chars);
    env->ReleaseStringUTFChars(js, chars);
    return out;
}

static std::string getSysProp(JNIEnv* env, const char* key, const char* defVal) {
    jclass cls = env->FindClass("android/os/SystemProperties");
    if (clearIfException(env, "SystemProperties") || !cls) return defVal;
    jmethodID mid = env->GetStaticMethodID(cls, "get", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (clearIfException(env, "SystemProperties.get") || !mid) return defVal;
    jstring jres = (jstring)env->CallStaticObjectMethod(cls, mid, env->NewStringUTF(key), env->NewStringUTF(defVal));
    if (clearIfException(env, "Call SystemProperties.get") || !jres) return defVal;
    return jstrToUtf8(env, jres);
}

class VisualState {
public:
    jobject activityGlobal = nullptr;
    float density = 1.5f;
    bool darkMode = true;
    bool liquidGlass = true;
    int glassLevel = 2;          // 1 = Subtle, 2 = Balanced, 3 = Expressive
    std::string motionBlur = "ui"; // "ui" | "all" | "off"

    int dp(float v) const {
        int px = (int)(v * density + 0.5f);
        return (v > 0.0f && px < 1) ? 1 : px;
    }

    const M3Palette& pal() const {
        return darkMode ? kDarkPalette : kLightPalette;
    }

    void syncFromSystem(JNIEnv* env, jobject activity) {
        jclass actCls = env->GetObjectClass(activity);
        jobject res = env->CallObjectMethod(activity, env->GetMethodID(actCls, "getResources", "()Landroid/content/res/Resources;"));
        if (res && !clearIfException(env, "getResources")) {
            jclass resCls = env->GetObjectClass(res);
            jobject dm = env->CallObjectMethod(res, env->GetMethodID(resCls, "getDisplayMetrics", "()Landroid/util/DisplayMetrics;"));
            if (dm && !clearIfException(env, "getDisplayMetrics")) {
                jclass dmCls = env->GetObjectClass(dm);
                density = env->GetFloatField(dm, env->GetFieldID(dmCls, "density", "F"));
            }
            jobject cfg = env->CallObjectMethod(res, env->GetMethodID(resCls, "getConfiguration", "()Landroid/content/res/Configuration;"));
            if (cfg && !clearIfException(env, "getConfiguration")) {
                jclass cfgCls = env->GetObjectClass(cfg);
                int uiMode = env->GetIntField(cfg, env->GetFieldID(cfgCls, "uiMode", "I"));
                darkMode = ((uiMode & 0x30) == 0x20);
            }
        }

        std::string lg = getSysProp(env, "persist.fidebook.liquid_glass", "1");
        liquidGlass = !(lg == "0" || lg == "off" || lg == "false");

        std::string lv = getSysProp(env, "persist.fidebook.liquid_glass_level", "2");
        if (lv == "1" || lv == "subtle") glassLevel = 1;
        else if (lv == "3" || lv == "expressive") glassLevel = 3;
        else glassLevel = 2;

        std::string mb = getSysProp(env, "persist.fidebook.motion_blur", "ui");
        if (mb == "all" || mb == "1" || mb == "true") motionBlur = "all";
        else if (mb == "off" || mb == "0" || mb == "false") motionBlur = "off";
        else motionBlur = "ui";
    }

    void writeLiveFxCommand() {
        mkdir("/data/local/tmp/fidebook_oobe", 0777);
        const char* cmdPath = "/data/local/tmp/fidebook_oobe/fx.cmd";
        if (FILE* f = fopen(cmdPath, "w")) {
            fprintf(f, "LIQUID_GLASS=%d\n", liquidGlass ? 1 : 0);
            fprintf(f, "LIQUID_GLASS_LEVEL=%d\n", glassLevel);
            fprintf(f, "MOTION_BLUR=%s\n", motionBlur.c_str());
            fclose(f);
            chmod(cmdPath, 0666);
        }
        const char* trigPath = "/data/local/tmp/fidebook_oobe/fx.trigger";
        if (FILE* tf = fopen(trigPath, "w")) {
            fprintf(tf, "1\n");
            fclose(tf);
            chmod(trigPath, 0666);
        }
        LOGI("Applied live FideBookOS 1.25 FX: liquid_glass=%d level=%d motion_blur=%s",
             liquidGlass ? 1 : 0, glassLevel, motionBlur.c_str());
    }

    jobject makeClickListener(JNIEnv* env, int actionId) {
        jclass cls = env->FindClass("org/fidebookos/settings/visual/ActionClick");
        jmethodID ctor = env->GetMethodID(cls, "<init>", "(Lorg/fidebookos/settings/visual/VisualActivity;I)V");
        return env->NewObject(cls, ctor, activityGlobal, (jint)actionId);
    }

    jobject makeRoundedDrawable(JNIEnv* env, jint fillColor, float radiusDp, int strokeWidthPx = 0, jint strokeColor = 0) {
        jclass gdCls = env->FindClass("android/graphics/drawable/GradientDrawable");
        jobject gd = env->NewObject(gdCls, env->GetMethodID(gdCls, "<init>", "()V"));
        env->CallVoidMethod(gd, env->GetMethodID(gdCls, "setColor", "(I)V"), fillColor);
        env->CallVoidMethod(gd, env->GetMethodID(gdCls, "setCornerRadius", "(F)V"), radiusDp * density);
        if (strokeWidthPx > 0) {
            env->CallVoidMethod(gd, env->GetMethodID(gdCls, "setStroke", "(II)V"), (jint)strokeWidthPx, strokeColor);
        }
        return gd;
    }

    jobject makeGoogleGradientBar(JNIEnv* env) {
        jclass gdCls = env->FindClass("android/graphics/drawable/GradientDrawable");
        jclass oriCls = env->FindClass("android/graphics/drawable/GradientDrawable$Orientation");
        jobject lr = env->GetStaticObjectField(oriCls,
            env->GetStaticFieldID(oriCls, "LEFT_RIGHT", "Landroid/graphics/drawable/GradientDrawable$Orientation;"));
        jintArray colors = env->NewIntArray(4);
        jint stops[4] = {(jint)0xFF4285F4, (jint)0xFFEA4335, (jint)0xFFFBBC05, (jint)0xFF34A853};
        env->SetIntArrayRegion(colors, 0, 4, stops);
        return env->NewObject(gdCls,
            env->GetMethodID(gdCls, "<init>", "(Landroid/graphics/drawable/GradientDrawable$Orientation;[I)V"),
            lr, colors);
    }

    jobject makeRippleSurface(JNIEnv* env, jint fillColor, float radiusDp, jint rippleColor, int strokeWidthPx = 0, jint strokeColor = 0) {
        jobject content = makeRoundedDrawable(env, fillColor, radiusDp, strokeWidthPx, strokeColor);
        jobject mask = makeRoundedDrawable(env, (jint)0xFFFFFFFF, radiusDp, 0, 0);
        jclass cslCls = env->FindClass("android/content/res/ColorStateList");
        jobject csl = env->CallStaticObjectMethod(cslCls,
            env->GetStaticMethodID(cslCls, "valueOf", "(I)Landroid/content/res/ColorStateList;"), rippleColor);
        jclass ripCls = env->FindClass("android/graphics/drawable/RippleDrawable");
        return env->NewObject(ripCls,
            env->GetMethodID(ripCls, "<init>", "(Landroid/content/res/ColorStateList;Landroid/graphics/drawable/Drawable;Landroid/graphics/drawable/Drawable;)V"),
            csl, content, mask);
    }

    void setViewBg(JNIEnv* env, jobject view, jobject drawable) {
        env->CallVoidMethod(view, env->GetMethodID(env->FindClass("android/view/View"), "setBackground", "(Landroid/graphics/drawable/Drawable;)V"), drawable);
    }

    void setPadding(JNIEnv* env, jobject view, int l, int t, int r, int b) {
        env->CallVoidMethod(view, env->GetMethodID(env->FindClass("android/view/View"), "setPadding", "(IIII)V"), l, t, r, b);
    }

    void attachAction(JNIEnv* env, jobject view, int actionId) {
        jclass vCls = env->FindClass("android/view/View");
        env->CallVoidMethod(view, env->GetMethodID(vCls, "setClickable", "(Z)V"), JNI_TRUE);
        env->CallVoidMethod(view, env->GetMethodID(vCls, "setFocusable", "(Z)V"), JNI_TRUE);
        env->CallVoidMethod(view, env->GetMethodID(vCls, "setOnClickListener", "(Landroid/view/View$OnClickListener;)V"),
                            makeClickListener(env, actionId));
    }

    jobject makeLinear(JNIEnv* env, bool vertical) {
        jclass cls = env->FindClass("android/widget/LinearLayout");
        jobject ll = env->NewObject(cls, env->GetMethodID(cls, "<init>", "(Landroid/content/Context;)V"), activityGlobal);
        env->CallVoidMethod(ll, env->GetMethodID(cls, "setOrientation", "(I)V"), vertical ? 1 : 0);
        return ll;
    }

    jobject makeLP(JNIEnv* env, int w, int h, float weight = 0.0f, int ml = 0, int mt = 0, int mr = 0, int mb = 0) {
        jclass cls = env->FindClass("android/widget/LinearLayout$LayoutParams");
        jobject lp = (weight > 0.0f)
            ? env->NewObject(cls, env->GetMethodID(cls, "<init>", "(IIF)V"), w, h, weight)
            : env->NewObject(cls, env->GetMethodID(cls, "<init>", "(II)V"), w, h);
        env->CallVoidMethod(lp, env->GetMethodID(cls, "setMargins", "(IIII)V"), ml, mt, mr, mb);
        return lp;
    }

    void addView(JNIEnv* env, jobject parent, jobject child, jobject lp) {
        env->CallVoidMethod(parent,
            env->GetMethodID(env->FindClass("android/view/ViewGroup"), "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V"),
            child, lp);
    }

    jobject makeText(JNIEnv* env, const std::string& text, float spSize, jint color, bool mediumWeight = false, float lineMult = 1.25f) {
        jclass cls = env->FindClass("android/widget/TextView");
        jobject tv = env->NewObject(cls, env->GetMethodID(cls, "<init>", "(Landroid/content/Context;)V"), activityGlobal);
        env->CallVoidMethod(tv, env->GetMethodID(cls, "setText", "(Ljava/lang/CharSequence;)V"), env->NewStringUTF(text.c_str()));
        env->CallVoidMethod(tv, env->GetMethodID(cls, "setTextSize", "(IF)V"), (jint)2, spSize);
        env->CallVoidMethod(tv, env->GetMethodID(cls, "setTextColor", "(I)V"), color);
        env->CallVoidMethod(tv, env->GetMethodID(cls, "setLineSpacing", "(FF)V"), 0.0f, lineMult);
        jclass tfCls = env->FindClass("android/graphics/Typeface");
        jobject tf = env->CallStaticObjectMethod(tfCls,
            env->GetStaticMethodID(tfCls, "create", "(Ljava/lang/String;I)Landroid/graphics/Typeface;"),
            env->NewStringUTF(mediumWeight ? "sans-serif-medium" : "sans-serif"), (jint)0);
        if (tf && !clearIfException(env, "Typeface")) {
            env->CallVoidMethod(tv, env->GetMethodID(cls, "setTypeface", "(Landroid/graphics/Typeface;)V"), tf);
        }
        return tv;
    }

    jobject makeLogoView(JNIEnv* env) {
        jclass ivCls = env->FindClass("android/widget/ImageView");
        jobject iv = env->NewObject(ivCls, env->GetMethodID(ivCls, "<init>", "(Landroid/content/Context;)V"), activityGlobal);
        const int W = FIDEBOOK_LOGO_W, H = FIDEBOOK_LOGO_H;
        std::vector<jint> argb(W * H);
        for (int i = 0; i < W * H; ++i) {
            uint8_t r = fidebook_logo_rgba[i * 4 + 0];
            uint8_t g = fidebook_logo_rgba[i * 4 + 1];
            uint8_t b = fidebook_logo_rgba[i * 4 + 2];
            uint8_t a = fidebook_logo_rgba[i * 4 + 3];
            argb[i] = ((jint)a << 24) | ((jint)r << 16) | ((jint)g << 8) | (jint)b;
        }
        jintArray jpx = env->NewIntArray(W * H);
        env->SetIntArrayRegion(jpx, 0, W * H, argb.data());
        jclass cfgCls = env->FindClass("android/graphics/Bitmap$Config");
        jobject cfg = env->GetStaticObjectField(cfgCls, env->GetStaticFieldID(cfgCls, "ARGB_8888", "Landroid/graphics/Bitmap$Config;"));
        jclass bmpCls = env->FindClass("android/graphics/Bitmap");
        jobject bmp = env->CallStaticObjectMethod(bmpCls,
            env->GetStaticMethodID(bmpCls, "createBitmap", "([IIILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;"),
            jpx, W, H, cfg);
        if (bmp && !clearIfException(env, "Bitmap")) {
            env->CallVoidMethod(iv, env->GetMethodID(ivCls, "setImageBitmap", "(Landroid/graphics/Bitmap;)V"), bmp);
        }
        return iv;
    }

    jobject makeCard(JNIEnv* env, const std::string& title, const std::string& subtitle,
                     bool selected, int actionId, const std::string& badgeText = "") {
        const M3Palette& p = pal();
        jobject row = makeLinear(env, false);
        env->CallVoidMethod(row, env->GetMethodID(env->FindClass("android/widget/LinearLayout"), "setGravity", "(I)V"), 16);
        setPadding(env, row, dp(18), dp(14), dp(18), dp(14));
        jint bg = selected ? p.surfaceCardSelected : p.surfaceCard;
        int sw = selected ? dp(2) : dp(1);
        jint sc = selected ? p.primary : p.outlineVariant;
        if (actionId > 0) {
            setViewBg(env, row, makeRippleSurface(env, bg, 18.0f, p.rippleOnSurface, sw, sc));
            attachAction(env, row, actionId);
        } else {
            setViewBg(env, row, makeRoundedDrawable(env, bg, 18.0f, sw, sc));
        }
        jobject col = makeLinear(env, true);
        addView(env, col, makeText(env, title, 15.0f, p.onSurface, true), makeLP(env, -1, -2));
        if (!subtitle.empty()) {
            addView(env, col, makeText(env, subtitle, 12.5f, p.onSurfaceVariant, false, 1.3f),
                    makeLP(env, -1, -2, 0.0f, 0, dp(3), 0, 0));
        }
        addView(env, row, col, makeLP(env, 0, -2, 1.0f, 0, 0, dp(12), 0));

        std::string btxt = badgeText.empty() && selected ? "Active" : badgeText;
        if (!btxt.empty()) {
            jobject pill = makeLinear(env, false);
            setPadding(env, pill, dp(12), dp(5), dp(12), dp(5));
            setViewBg(env, pill, makeRoundedDrawable(env, selected ? p.primary : p.secondaryContainer, 14.0f));
            addView(env, pill, makeText(env, btxt, 11.5f, selected ? p.onPrimary : p.onSecondaryContainer, true, 1.0f),
                    makeLP(env, -2, -2));
            addView(env, row, pill, makeLP(env, -2, -2));
        }
        return row;
    }

    void rebuildUi(JNIEnv* env) {
        if (env->PushLocalFrame(256) < 0) return;
        const M3Palette& p = pal();

        jclass actCls = env->GetObjectClass(activityGlobal);
        jobject win = env->CallObjectMethod(activityGlobal, env->GetMethodID(actCls, "getWindow", "()Landroid/view/Window;"));
        if (win && !clearIfException(env, "getWindow")) {
            jclass winCls = env->GetObjectClass(win);
            env->CallVoidMethod(win, env->GetMethodID(winCls, "setStatusBarColor", "(I)V"), p.bgCanvas);
            env->CallVoidMethod(win, env->GetMethodID(winCls, "setNavigationBarColor", "(I)V"), p.bgCanvas);
            clearIfException(env, "setBarColors");
        }

        jobject outer = makeLinear(env, true);
        jclass llCls = env->FindClass("android/widget/LinearLayout");
        jmethodID setGrav = env->GetMethodID(llCls, "setGravity", "(I)V");
        env->CallVoidMethod(outer, setGrav, 1 /* CENTER_HORIZONTAL */);
        setViewBg(env, outer, makeRoundedDrawable(env, p.bgCanvas, 0.0f));

        jclass svCls = env->FindClass("android/widget/ScrollView");
        jobject scroll = env->NewObject(svCls, env->GetMethodID(svCls, "<init>", "(Landroid/content/Context;)V"), activityGlobal);
        env->CallVoidMethod(scroll, env->GetMethodID(svCls, "setFillViewport", "(Z)V"), JNI_TRUE);

        jobject wrap = makeLinear(env, true);
        env->CallVoidMethod(wrap, setGrav, 1 /* CENTER_HORIZONTAL */);
        setPadding(env, wrap, dp(24), dp(20), dp(24), dp(28));

        jobject container = makeLinear(env, true);
        setViewBg(env, container, makeRoundedDrawable(env, p.surfaceShell, 26.0f, dp(1), p.outlineVariant));

        jobject gradBar = makeLinear(env, false);
        setViewBg(env, gradBar, makeGoogleGradientBar(env));
        addView(env, container, gradBar, makeLP(env, -1, dp(4)));

        jobject content = makeLinear(env, true);
        setPadding(env, content, dp(24), dp(20), dp(24), dp(24));

        // Top Bar: Back pill + "F" Logo + Title + FideBookOS 1.25 badge
        jobject topRow = makeLinear(env, false);
        env->CallVoidMethod(topRow, setGrav, 16 /* CENTER_VERTICAL */);

        jobject backBtn = makeLinear(env, false);
        env->CallVoidMethod(backBtn, setGrav, 17);
        setPadding(env, backBtn, dp(14), dp(8), dp(14), dp(8));
        setViewBg(env, backBtn, makeRippleSurface(env, p.secondaryContainer, 18.0f, p.rippleOnSurface));
        addView(env, backBtn, makeText(env, "\xE2\x86\x90  Settings", 13.0f, p.onSecondaryContainer, true, 1.0f),
                makeLP(env, -2, -2));
        attachAction(env, backBtn, VACT_BACK);
        addView(env, topRow, backBtn, makeLP(env, -2, -2, 0.0f, 0, 0, dp(14), 0));

        addView(env, topRow, makeLogoView(env), makeLP(env, dp(36), dp(36), 0.0f, 0, 0, dp(12), 0));
        addView(env, topRow, makeText(env, "Liquid Glass & Motion", 22.0f, p.onSurface, true, 1.1f),
                makeLP(env, 0, -2, 1.0f));

        jobject verBadge = makeLinear(env, false);
        setPadding(env, verBadge, dp(12), dp(5), dp(12), dp(5));
        setViewBg(env, verBadge, makeRoundedDrawable(env, p.secondaryContainer, 14.0f));
        addView(env, verBadge, makeText(env, "FideBookOS 1.25", 12.0f, p.onSecondaryContainer, true, 1.0f),
                makeLP(env, -2, -2));
        addView(env, topRow, verBadge, makeLP(env, -2, -2));
        addView(env, content, topRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(18)));

        // Live Optics Banner
        jobject banner = makeLinear(env, true);
        setPadding(env, banner, dp(18), dp(14), dp(18), dp(14));
        setViewBg(env, banner, makeRoundedDrawable(env, liquidGlass ? p.successBg : p.surfaceHero, 18.0f, dp(1), p.outlineVariant));
        addView(env, banner, makeText(env,
                liquidGlass ? "Liquid Glass Optics Active — Taskbar, Control Center & App Menu"
                            : "Liquid Glass Disabled — Using Standard Material 3 Solid Panels",
                14.0f, liquidGlass ? p.successFg : p.onSurface, true),
                makeLP(env, -1, -2));
        addView(env, banner, makeText(env,
                "GPU Snell's-law meniscus refraction (IOR 1.52), 3-channel RGB prismatic dispersion, and Fresnel crystal rim sheen — toggled live with zero reboot.",
                12.5f, p.onSurfaceVariant, false, 1.35f),
                makeLP(env, -1, -2, 0.0f, 0, dp(4), 0, 0));
        addView(env, content, banner, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(18)));

        // Section 1: Liquid Glass ON / OFF
        addView(env, content, makeText(env, "Liquid Glass Background Refraction", 13.5f, p.onSurfaceVariant, true),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
        jobject glassToggleRow = makeLinear(env, false);
        addView(env, glassToggleRow, makeCard(env,
                "Enabled",
                "Refract live wallpaper & windows behind Taskbar, Control Center & App Menu.",
                liquidGlass, VACT_GLASS_ON, liquidGlass ? "On" : ""),
                makeLP(env, 0, -2, 1.0f, 0, 0, dp(6), 0));
        addView(env, glassToggleRow, makeCard(env,
                "Off",
                "Use standard Material 3 opaque/translucent surfaces.",
                !liquidGlass, VACT_GLASS_OFF, !liquidGlass ? "Off" : ""),
                makeLP(env, 0, -2, 1.0f, dp(6), 0, 0, 0));
        addView(env, content, glassToggleRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(16)));

        // Section 2: Refraction Lens Intensity
        addView(env, content, makeText(env, "Refraction Lens Depth & Dispersion", 13.5f, p.onSurfaceVariant, true),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
        jobject lvlRow = makeLinear(env, false);
        struct LvlOpt { int lv; const char* lbl; int act; } lvls[3] = {
            {1, "Subtle (18px)", VACT_LEVEL_1},
            {2, "Balanced (30px)", VACT_LEVEL_2},
            {3, "Expressive (44px)", VACT_LEVEL_3},
        };
        for (int i = 0; i < 3; ++i) {
            bool sel = (glassLevel == lvls[i].lv);
            jobject chip = makeLinear(env, false);
            env->CallVoidMethod(chip, setGrav, 17);
            setPadding(env, chip, dp(12), dp(12), dp(12), dp(12));
            setViewBg(env, chip, makeRippleSurface(env, sel ? p.surfaceCardSelected : p.surfaceCard,
                      16.0f, p.rippleOnSurface, sel ? dp(2) : dp(1), sel ? p.primary : p.outlineVariant));
            attachAction(env, chip, lvls[i].act);
            addView(env, chip, makeText(env, lvls[i].lbl, 13.0f, sel ? p.primary : p.onSurface, true, 1.0f),
                    makeLP(env, -2, -2));
            addView(env, lvlRow, chip, makeLP(env, 0, -2, 1.0f, i == 0 ? 0 : dp(5), 0, i == 2 ? 0 : dp(5), 0));
        }
        addView(env, content, lvlRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(18)));

        // Section 3: GPU Scroll Motion Blur
        addView(env, content, makeText(env, "Hardware GPU Scroll Motion Blur", 13.5f, p.onSurfaceVariant, true),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
        addView(env, content, makeCard(env,
                "UI Scroll Motion Blur (Recommended)",
                "60 FPS directional shutter blur in App Menu, Settings & Control Center.",
                motionBlur == "ui", VACT_MBLUR_UI),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
        addView(env, content, makeCard(env,
                "Everywhere (Apps + Games)",
                "Apply hardware directional shutter blur across all Vulkan-accelerated apps.",
                motionBlur == "all", VACT_MBLUR_ALL),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
        addView(env, content, makeCard(env,
                "Off",
                "Disable directional scroll motion blur.",
                motionBlur == "off", VACT_MBLUR_OFF),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(4)));

        addView(env, container, content, makeLP(env, -1, -2));

        int maxW = dp(860);
        jobject res = env->CallObjectMethod(activityGlobal, env->GetMethodID(actCls, "getResources", "()Landroid/content/res/Resources;"));
        if (res && !clearIfException(env, "res")) {
            jobject dm = env->CallObjectMethod(res, env->GetMethodID(env->GetObjectClass(res), "getDisplayMetrics", "()Landroid/util/DisplayMetrics;"));
            if (dm && !clearIfException(env, "dm")) {
                int wPx = env->GetIntField(dm, env->GetFieldID(env->GetObjectClass(dm), "widthPixels", "I"));
                if (wPx > 0 && maxW > wPx - dp(48)) maxW = wPx - dp(48);
            }
        }
        addView(env, wrap, container, makeLP(env, maxW, -2));
        addView(env, scroll, wrap, makeLP(env, -1, -2));
        addView(env, outer, scroll, makeLP(env, -1, -1));

        env->CallVoidMethod(activityGlobal, env->GetMethodID(actCls, "setContentView", "(Landroid/view/View;)V"), outer);
        clearIfException(env, "setContentView");
        env->PopLocalFrame(nullptr);
    }

    void handleAction(JNIEnv* env, int actionId) {
        switch (actionId) {
            case VACT_BACK: {
                jclass actCls = env->GetObjectClass(activityGlobal);
                env->CallVoidMethod(activityGlobal, env->GetMethodID(actCls, "finish", "()V"));
                return;
            }
            case VACT_GLASS_ON:  liquidGlass = true;  break;
            case VACT_GLASS_OFF: liquidGlass = false; break;
            case VACT_LEVEL_1:   glassLevel = 1; liquidGlass = true; break;
            case VACT_LEVEL_2:   glassLevel = 2; liquidGlass = true; break;
            case VACT_LEVEL_3:   glassLevel = 3; liquidGlass = true; break;
            case VACT_MBLUR_UI:  motionBlur = "ui";   break;
            case VACT_MBLUR_ALL: motionBlur = "all";  break;
            case VACT_MBLUR_OFF: motionBlur = "off";  break;
            default: return;
        }
        writeLiveFxCommand();
        rebuildUi(env);
    }
};

static VisualState* getPtr(JNIEnv* env, jobject thiz) {
    jclass cls = env->GetObjectClass(thiz);
    return reinterpret_cast<VisualState*>(env->GetLongField(thiz, env->GetFieldID(cls, "nativePtr", "J")));
}

static void setPtr(JNIEnv* env, jobject thiz, VisualState* st) {
    jclass cls = env->GetObjectClass(thiz);
    env->SetLongField(thiz, env->GetFieldID(cls, "nativePtr", "J"), reinterpret_cast<jlong>(st));
}

} // namespace

extern "C" {

JNIEXPORT void JNICALL
Java_org_fidebookos_settings_visual_VisualActivity_nativeOnCreate(JNIEnv* env, jobject thiz, jobject /*savedInstanceState*/) {
    jclass actCls = env->GetObjectClass(thiz);
    env->CallBooleanMethod(thiz, env->GetMethodID(actCls, "requestWindowFeature", "(I)Z"), (jint)1);
    clearIfException(env, "requestWindowFeature");

    auto* st = new VisualState();
    st->activityGlobal = env->NewGlobalRef(thiz);
    st->syncFromSystem(env, thiz);
    setPtr(env, thiz, st);
    st->rebuildUi(env);
}

JNIEXPORT void JNICALL
Java_org_fidebookos_settings_visual_VisualActivity_nativeOnResume(JNIEnv* env, jobject thiz) {
    if (auto* st = getPtr(env, thiz)) {
        st->syncFromSystem(env, thiz);
        st->rebuildUi(env);
    }
}

JNIEXPORT void JNICALL
Java_org_fidebookos_settings_visual_VisualActivity_nativeOnBack(JNIEnv* env, jobject thiz) {
    jclass actCls = env->GetObjectClass(thiz);
    env->CallVoidMethod(thiz, env->GetMethodID(actCls, "finish", "()V"));
}

JNIEXPORT void JNICALL
Java_org_fidebookos_settings_visual_VisualActivity_nativeOnAction(JNIEnv* env, jobject thiz, jint actionId, jobject /*view*/) {
    if (auto* st = getPtr(env, thiz)) {
        st->handleAction(env, (int)actionId);
    }
}

JNIEXPORT void JNICALL
Java_org_fidebookos_settings_visual_VisualActivity_nativeOnDestroy(JNIEnv* env, jobject thiz) {
    if (auto* st = getPtr(env, thiz)) {
        if (st->activityGlobal) {
            env->DeleteGlobalRef(st->activityGlobal);
            st->activityGlobal = nullptr;
        }
        setPtr(env, thiz, nullptr);
        delete st;
    }
}

} // extern "C"
