// FideBookOS 1.25 — Native Material 3 Expressive Laptop Setup Wizard (libfidebook_setup.so)
// Built 100% offline with Android NDK clang++ (-static-libstdc++) against public Android framework JNI APIs.

#include <jni.h>
#include <android/log.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>

#include "../fidebook_logo_rgba.h"

#define LOG_TAG "FideBookSetup"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

enum ActionId : int {
    ACT_NEXT = 1,
    ACT_BACK = 2,
    ACT_SKIP = 3,
    ACT_LANG = 10,
    ACT_A11Y = 11,
    ACT_WIFI = 20,
    ACT_BT = 21,
    ACT_REFRESH_NET = 22,
    ACT_KB_SETTINGS = 30,
    ACT_TP_FLICK_TOGGLE = 31,
    ACT_THEME_DARK = 40,
    ACT_THEME_LIGHT = 41,
    ACT_MBLUR_UI = 42,
    ACT_MBLUR_ALL = 43,
    ACT_MBLUR_OFF = 44,
    ACT_DPI_140 = 45,
    ACT_DPI_160 = 46,
    ACT_DPI_180 = 47,
    ACT_DPI_200 = 48,
    ACT_GLASS_ON = 49,
    ACT_GLASS_OFF = 52,
    ACT_TEST_CAMERA = 50,
    ACT_TEST_SOUND = 51,
    ACT_GOOGLE_SIGNIN = 60,
    ACT_FINISH = 99,
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
    jint rippleOnPrimary;
    jint successBg;
    jint successFg;
    jint warnBg;
    jint warnFg;
};

static const M3Palette kDarkPalette = {
    (jint)0xFF0B0F17, // bgCanvas
    (jint)0xFF131924, // surfaceShell
    (jint)0xFF0E141E, // surfaceHero
    (jint)0xFF1A2230, // surfaceCard
    (jint)0xFF1D3254, // surfaceCardSelected
    (jint)0xFFA8C7FA, // primary
    (jint)0xFF062E6F, // onPrimary
    (jint)0xFF223047, // secondaryContainer
    (jint)0xFFD3E3FD, // onSecondaryContainer
    (jint)0xFFE6EDF7, // onSurface
    (jint)0xFF9AA6B8, // onSurfaceVariant
    (jint)0xFF2B3547, // outlineVariant
    (jint)0x33A8C7FA, // rippleOnSurface
    (jint)0x33062E6F, // rippleOnPrimary
    (jint)0xFF123824, // successBg
    (jint)0xFF6DD58C, // successFg
    (jint)0xFF3B2E11, // warnBg
    (jint)0xFFFDD663, // warnFg
};

static const M3Palette kLightPalette = {
    (jint)0xFFEEF3FA, // bgCanvas
    (jint)0xFFFFFFFF, // surfaceShell
    (jint)0xFFF3F7FE, // surfaceHero
    (jint)0xFFF5F8FD, // surfaceCard
    (jint)0xFFD3E3FD, // surfaceCardSelected
    (jint)0xFF0B57D0, // primary
    (jint)0xFFFFFFFF, // onPrimary
    (jint)0xFFD3E3FD, // secondaryContainer
    (jint)0xFF041E49, // onSecondaryContainer
    (jint)0xFF1B1F26, // onSurface
    (jint)0xFF475061, // onSurfaceVariant
    (jint)0xFFD6DCE8, // outlineVariant
    (jint)0x260B57D0, // rippleOnSurface
    (jint)0x33FFFFFF, // rippleOnPrimary
    (jint)0xFFE6F4EA, // successBg
    (jint)0xFF137333, // successFg
    (jint)0xFFFEF7E0, // warnBg
    (jint)0xFFB06000, // warnFg
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

static std::string sanitizeConfigVal(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    for (char c : in) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == ' ' || c == '-' || c == '_' || c == '.') {
            out.push_back(c);
        }
    }
    while (!out.empty() && out.front() == ' ') out.erase(out.begin());
    while (!out.empty() && out.back() == ' ') out.pop_back();
    if (out.size() > 40) out.resize(40);
    return out;
}

static std::string getSysProp(JNIEnv* env, const char* key, const char* defVal) {
    jclass cls = env->FindClass("android/os/SystemProperties");
    if (clearIfException(env, "FindClass SystemProperties") || !cls) return defVal;
    jmethodID mid = env->GetStaticMethodID(cls, "get", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (clearIfException(env, "SystemProperties.get") || !mid) return defVal;
    jstring jk = env->NewStringUTF(key);
    jstring jd = env->NewStringUTF(defVal);
    jstring jres = (jstring)env->CallStaticObjectMethod(cls, mid, jk, jd);
    if (clearIfException(env, "Call SystemProperties.get") || !jres) return defVal;
    return jstrToUtf8(env, jres);
}

class SetupState {
public:
    jobject activityGlobal = nullptr;
    jobject nameEditGlobal = nullptr;
    float density = 1.5f;

    int step = 0; // 0..5 (6 steps)
    int lastStepDir = 1;
    bool darkMode = true;
    bool liquidGlass = true;
    std::string deviceName = "FideBook";
    std::string motionBlur = "ui"; // "ui" | "all" | "off"
    int targetDpi = 160;
    bool touchpadFlickBoost = true;

    int dp(float v) const {
        int px = (int)(v * density + 0.5f);
        return (v > 0.0f && px < 1) ? 1 : px;
    }

    const M3Palette& pal() const {
        return darkMode ? kDarkPalette : kLightPalette;
    }

    void initFromSystem(JNIEnv* env, jobject activity) {
        // Read display metrics density
        jclass actCls = env->GetObjectClass(activity);
        jmethodID getRes = env->GetMethodID(actCls, "getResources", "()Landroid/content/res/Resources;");
        jobject res = env->CallObjectMethod(activity, getRes);
        if (res && !clearIfException(env, "getResources")) {
            jclass resCls = env->GetObjectClass(res);
            jmethodID getDm = env->GetMethodID(resCls, "getDisplayMetrics", "()Landroid/util/DisplayMetrics;");
            jobject dm = env->CallObjectMethod(res, getDm);
            if (dm && !clearIfException(env, "getDisplayMetrics")) {
                jclass dmCls = env->GetObjectClass(dm);
                jfieldID densFid = env->GetFieldID(dmCls, "density", "F");
                jfieldID dpiFid = env->GetFieldID(dmCls, "densityDpi", "I");
                density = env->GetFloatField(dm, densFid);
                int curDpi = env->GetIntField(dm, dpiFid);
                if (curDpi >= 130 && curDpi <= 150) targetDpi = 140;
                else if (curDpi >= 151 && curDpi <= 170) targetDpi = 160;
                else if (curDpi >= 171 && curDpi <= 190) targetDpi = 180;
                else if (curDpi > 190) targetDpi = 200;
            }
        }

        std::string model = getSysProp(env, "ro.product.model", "FideBook");
        if (!model.empty() && model.find("Googlebook") == std::string::npos) {
            deviceName = model;
        }
        std::string mb = getSysProp(env, "persist.fidebook.motion_blur", "ui");
        if (mb == "all" || mb == "1" || mb == "true") motionBlur = "all";
        else if (mb == "off" || mb == "0" || mb == "false") motionBlur = "off";
        else motionBlur = "ui";

        std::string lg = getSysProp(env, "persist.fidebook.liquid_glass", "1");
        liquidGlass = !(lg == "0" || lg == "off" || lg == "false");
    }

    void captureEditTextIfPresent(JNIEnv* env) {
        if (!nameEditGlobal) return;
        jclass tvCls = env->FindClass("android/widget/EditText");
        jmethodID getText = env->GetMethodID(tvCls, "getText", "()Landroid/text/Editable;");
        jobject editable = env->CallObjectMethod(nameEditGlobal, getText);
        if (editable && !clearIfException(env, "EditText.getText")) {
            jclass objCls = env->FindClass("java/lang/Object");
            jmethodID toStr = env->GetMethodID(objCls, "toString", "()Ljava/lang/String;");
            jstring js = (jstring)env->CallObjectMethod(editable, toStr);
            if (js && !clearIfException(env, "Editable.toString")) {
                std::string cleaned = sanitizeConfigVal(jstrToUtf8(env, js));
                if (!cleaned.empty()) {
                    deviceName = cleaned;
                }
            }
        }
    }

    void clearNameEditRef(JNIEnv* env) {
        if (nameEditGlobal) {
            env->DeleteGlobalRef(nameEditGlobal);
            nameEditGlobal = nullptr;
        }
    }

    jobject makeClickListener(JNIEnv* env, int actionId) {
        jclass cls = env->FindClass("org/fidebookos/setup/ActionClick");
        jmethodID ctor = env->GetMethodID(cls, "<init>", "(Lorg/fidebookos/setup/SetupActivity;I)V");
        return env->NewObject(cls, ctor, activityGlobal, (jint)actionId);
    }

    jobject makeRoundedDrawable(JNIEnv* env, jint fillColor, float radiusDp, int strokeWidthPx = 0, jint strokeColor = 0) {
        jclass gdCls = env->FindClass("android/graphics/drawable/GradientDrawable");
        jmethodID ctor = env->GetMethodID(gdCls, "<init>", "()V");
        jobject gd = env->NewObject(gdCls, ctor);
        jmethodID setColor = env->GetMethodID(gdCls, "setColor", "(I)V");
        jmethodID setCornerRadius = env->GetMethodID(gdCls, "setCornerRadius", "(F)V");
        env->CallVoidMethod(gd, setColor, fillColor);
        env->CallVoidMethod(gd, setCornerRadius, radiusDp * density);
        if (strokeWidthPx > 0) {
            jmethodID setStroke = env->GetMethodID(gdCls, "setStroke", "(II)V");
            env->CallVoidMethod(gd, setStroke, (jint)strokeWidthPx, strokeColor);
        }
        return gd;
    }

    jobject makeGoogleGradientBar(JNIEnv* env) {
        jclass gdCls = env->FindClass("android/graphics/drawable/GradientDrawable");
        jclass oriCls = env->FindClass("android/graphics/drawable/GradientDrawable$Orientation");
        jfieldID lrFid = env->GetStaticFieldID(oriCls, "LEFT_RIGHT", "Landroid/graphics/drawable/GradientDrawable$Orientation;");
        jobject lr = env->GetStaticObjectField(oriCls, lrFid);
        jintArray colors = env->NewIntArray(4);
        jint stops[4] = {(jint)0xFF4285F4, (jint)0xFFEA4335, (jint)0xFFFBBC05, (jint)0xFF34A853};
        env->SetIntArrayRegion(colors, 0, 4, stops);
        jmethodID ctor = env->GetMethodID(gdCls, "<init>", "(Landroid/graphics/drawable/GradientDrawable$Orientation;[I)V");
        jobject gd = env->NewObject(gdCls, ctor, lr, colors);
        return gd;
    }

    jobject makeRippleSurface(JNIEnv* env, jint fillColor, float radiusDp, jint rippleColor, int strokeWidthPx = 0, jint strokeColor = 0) {
        jobject content = makeRoundedDrawable(env, fillColor, radiusDp, strokeWidthPx, strokeColor);
        jobject mask = makeRoundedDrawable(env, (jint)0xFFFFFFFF, radiusDp, 0, 0);
        jclass cslCls = env->FindClass("android/content/res/ColorStateList");
        jmethodID valOf = env->GetStaticMethodID(cslCls, "valueOf", "(I)Landroid/content/res/ColorStateList;");
        jobject csl = env->CallStaticObjectMethod(cslCls, valOf, rippleColor);
        jclass ripCls = env->FindClass("android/graphics/drawable/RippleDrawable");
        jmethodID ctor = env->GetMethodID(ripCls, "<init>",
            "(Landroid/content/res/ColorStateList;Landroid/graphics/drawable/Drawable;Landroid/graphics/drawable/Drawable;)V");
        return env->NewObject(ripCls, ctor, csl, content, mask);
    }

    void setViewBg(JNIEnv* env, jobject view, jobject drawable) {
        jclass vCls = env->FindClass("android/view/View");
        jmethodID mid = env->GetMethodID(vCls, "setBackground", "(Landroid/graphics/drawable/Drawable;)V");
        env->CallVoidMethod(view, mid, drawable);
    }

    void setPadding(JNIEnv* env, jobject view, int l, int t, int r, int b) {
        jclass vCls = env->FindClass("android/view/View");
        jmethodID mid = env->GetMethodID(vCls, "setPadding", "(IIII)V");
        env->CallVoidMethod(view, mid, l, t, r, b);
    }

    void setElevation(JNIEnv* env, jobject view, float dpVal) {
        jclass vCls = env->FindClass("android/view/View");
        jmethodID mid = env->GetMethodID(vCls, "setElevation", "(F)V");
        env->CallVoidMethod(view, mid, dpVal * density);
    }

    void setClipToOutline(JNIEnv* env, jobject view, bool clip) {
        jclass vCls = env->FindClass("android/view/View");
        jmethodID mid = env->GetMethodID(vCls, "setClipToOutline", "(Z)V");
        env->CallVoidMethod(view, mid, clip ? JNI_TRUE : JNI_FALSE);
    }

    void attachAction(JNIEnv* env, jobject view, int actionId) {
        jclass vCls = env->FindClass("android/view/View");
        jmethodID setClick = env->GetMethodID(vCls, "setOnClickListener", "(Landroid/view/View$OnClickListener;)V");
        jmethodID setClickable = env->GetMethodID(vCls, "setClickable", "(Z)V");
        jmethodID setFocusable = env->GetMethodID(vCls, "setFocusable", "(Z)V");
        env->CallVoidMethod(view, setClickable, JNI_TRUE);
        env->CallVoidMethod(view, setFocusable, JNI_TRUE);
        env->CallVoidMethod(view, setClick, makeClickListener(env, actionId));
    }

    jobject makeLinear(JNIEnv* env, bool vertical) {
        jclass cls = env->FindClass("android/widget/LinearLayout");
        jmethodID ctor = env->GetMethodID(cls, "<init>", "(Landroid/content/Context;)V");
        jobject ll = env->NewObject(cls, ctor, activityGlobal);
        jmethodID setOri = env->GetMethodID(cls, "setOrientation", "(I)V");
        env->CallVoidMethod(ll, setOri, vertical ? 1 : 0);
        return ll;
    }

    jobject makeLP(JNIEnv* env, int w, int h, float weight = 0.0f, int ml = 0, int mt = 0, int mr = 0, int mb = 0, int gravity = -1) {
        jclass cls = env->FindClass("android/widget/LinearLayout$LayoutParams");
        jobject lp;
        if (weight > 0.0f) {
            jmethodID ctor = env->GetMethodID(cls, "<init>", "(IIF)V");
            lp = env->NewObject(cls, ctor, w, h, weight);
        } else {
            jmethodID ctor = env->GetMethodID(cls, "<init>", "(II)V");
            lp = env->NewObject(cls, ctor, w, h);
        }
        jmethodID setMargins = env->GetMethodID(cls, "setMargins", "(IIII)V");
        env->CallVoidMethod(lp, setMargins, ml, mt, mr, mb);
        if (gravity >= 0) {
            jfieldID gFid = env->GetFieldID(cls, "gravity", "I");
            env->SetIntField(lp, gFid, gravity);
        }
        return lp;
    }

    void addView(JNIEnv* env, jobject parent, jobject child, jobject lp) {
        jclass vgCls = env->FindClass("android/view/ViewGroup");
        jmethodID mid = env->GetMethodID(vgCls, "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V");
        env->CallVoidMethod(parent, mid, child, lp);
    }

    jobject makeText(JNIEnv* env, const std::string& text, float spSize, jint color, bool mediumWeight = false, float lineMult = 1.25f) {
        jclass cls = env->FindClass("android/widget/TextView");
        jmethodID ctor = env->GetMethodID(cls, "<init>", "(Landroid/content/Context;)V");
        jobject tv = env->NewObject(cls, ctor, activityGlobal);
        jmethodID setText = env->GetMethodID(cls, "setText", "(Ljava/lang/CharSequence;)V");
        jmethodID setSize = env->GetMethodID(cls, "setTextSize", "(IF)V");
        jmethodID setColor = env->GetMethodID(cls, "setTextColor", "(I)V");
        jmethodID setLine = env->GetMethodID(cls, "setLineSpacing", "(FF)V");
        env->CallVoidMethod(tv, setText, env->NewStringUTF(text.c_str()));
        env->CallVoidMethod(tv, setSize, (jint)2 /* COMPLEX_UNIT_SP */, spSize);
        env->CallVoidMethod(tv, setColor, color);
        env->CallVoidMethod(tv, setLine, 0.0f, lineMult);

        jclass tfCls = env->FindClass("android/graphics/Typeface");
        jmethodID tfCreate = env->GetStaticMethodID(tfCls, "create", "(Ljava/lang/String;I)Landroid/graphics/Typeface;");
        jobject tf = env->CallStaticObjectMethod(tfCls, tfCreate,
            env->NewStringUTF(mediumWeight ? "sans-serif-medium" : "sans-serif"), (jint)0);
        if (tf && !clearIfException(env, "Typeface.create")) {
            jmethodID setTf = env->GetMethodID(cls, "setTypeface", "(Landroid/graphics/Typeface;)V");
            env->CallVoidMethod(tv, setTf, tf);
        }
        return tv;
    }

    jobject makeLogoView(JNIEnv* env, int sizeDp) {
        jclass ivCls = env->FindClass("android/widget/ImageView");
        jmethodID ivCtor = env->GetMethodID(ivCls, "<init>", "(Landroid/content/Context;)V");
        jobject iv = env->NewObject(ivCls, ivCtor, activityGlobal);

        const int W = FIDEBOOK_LOGO_W;
        const int H = FIDEBOOK_LOGO_H;
        std::vector<jint> argb(W * H);
        for (int i = 0; i < W * H; ++i) {
            uint8_t r = fidebook_logo_rgba[i * 4 + 0];
            uint8_t g = fidebook_logo_rgba[i * 4 + 1];
            uint8_t b = fidebook_logo_rgba[i * 4 + 2];
            uint8_t a = fidebook_logo_rgba[i * 4 + 3];
            argb[i] = ((jint)a << 24) | ((jint)r << 16) | ((jint)g << 8) | (jint)b;
        }
        jintArray jpixels = env->NewIntArray(W * H);
        env->SetIntArrayRegion(jpixels, 0, W * H, argb.data());

        jclass cfgCls = env->FindClass("android/graphics/Bitmap$Config");
        jfieldID argbFid = env->GetStaticFieldID(cfgCls, "ARGB_8888", "Landroid/graphics/Bitmap$Config;");
        jobject cfg = env->GetStaticObjectField(cfgCls, argbFid);

        jclass bmpCls = env->FindClass("android/graphics/Bitmap");
        jmethodID createBmp = env->GetStaticMethodID(bmpCls, "createBitmap", "([IIILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
        jobject bmp = env->CallStaticObjectMethod(bmpCls, createBmp, jpixels, W, H, cfg);
        if (bmp && !clearIfException(env, "Bitmap.createBitmap")) {
            jmethodID setBmp = env->GetMethodID(ivCls, "setImageBitmap", "(Landroid/graphics/Bitmap;)V");
            env->CallVoidMethod(iv, setBmp, bmp);
        }
        (void)sizeDp;
        return iv;
    }

    jobject makePillButton(JNIEnv* env, const std::string& label, int actionId, bool filledPrimary) {
        const M3Palette& p = pal();
        jobject box = makeLinear(env, false);
        jclass llCls = env->FindClass("android/widget/LinearLayout");
        jmethodID setGrav = env->GetMethodID(llCls, "setGravity", "(I)V");
        env->CallVoidMethod(box, setGrav, 17 /* Gravity.CENTER */);
        setPadding(env, box, dp(24), dp(12), dp(24), dp(12));
        if (filledPrimary) {
            setViewBg(env, box, makeRippleSurface(env, p.primary, 24.0f, p.rippleOnPrimary, 0, 0));
            setElevation(env, box, 2.0f);
        } else {
            setViewBg(env, box, makeRippleSurface(env, 0x00000000, 24.0f, p.rippleOnSurface, dp(1), p.outlineVariant));
        }
        jobject tv = makeText(env, label, 14.0f, filledPrimary ? p.onPrimary : p.primary, true, 1.0f);
        addView(env, box, tv, makeLP(env, -2, -2));
        attachAction(env, box, actionId);
        return box;
    }

    jobject makeTonalButton(JNIEnv* env, const std::string& label, int actionId) {
        const M3Palette& p = pal();
        jobject box = makeLinear(env, false);
        jclass llCls = env->FindClass("android/widget/LinearLayout");
        env->CallVoidMethod(box, env->GetMethodID(llCls, "setGravity", "(I)V"), 17);
        setPadding(env, box, dp(18), dp(10), dp(18), dp(10));
        setViewBg(env, box, makeRippleSurface(env, p.secondaryContainer, 20.0f, p.rippleOnSurface, 0, 0));
        jobject tv = makeText(env, label, 13.0f, p.onSecondaryContainer, true, 1.0f);
        addView(env, box, tv, makeLP(env, -2, -2));
        attachAction(env, box, actionId);
        return box;
    }

    jobject makeOptionCard(JNIEnv* env, const std::string& title, const std::string& subtitle,
                           bool selected, int actionId, const std::string& trailingText = "") {
        const M3Palette& p = pal();
        jobject row = makeLinear(env, false);
        jclass llCls = env->FindClass("android/widget/LinearLayout");
        env->CallVoidMethod(row, env->GetMethodID(llCls, "setGravity", "(I)V"), 16 /* CENTER_VERTICAL */);
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

        std::string badge = trailingText;
        if (badge.empty() && selected) badge = "Selected";
        if (!badge.empty()) {
            jobject pill = makeLinear(env, false);
            setPadding(env, pill, dp(12), dp(5), dp(12), dp(5));
            setViewBg(env, pill, makeRoundedDrawable(env, selected ? p.primary : p.secondaryContainer, 14.0f));
            addView(env, pill, makeText(env, badge, 11.5f, selected ? p.onPrimary : p.onSecondaryContainer, true, 1.0f),
                    makeLP(env, -2, -2));
            addView(env, row, pill, makeLP(env, -2, -2));
        }
        return row;
    }

    // Live hardware / OS queries
    std::string queryLocaleDisplay(JNIEnv* env) {
        jclass cls = env->FindClass("java/util/Locale");
        if (clearIfException(env, "Locale")) return "English (United States)";
        jmethodID getDef = env->GetStaticMethodID(cls, "getDefault", "()Ljava/util/Locale;");
        jobject loc = env->CallStaticObjectMethod(cls, getDef);
        if (!loc || clearIfException(env, "Locale.getDefault")) return "English (United States)";
        jmethodID getDisp = env->GetMethodID(cls, "getDisplayName", "()Ljava/lang/String;");
        jstring js = (jstring)env->CallObjectMethod(loc, getDisp);
        if (!js || clearIfException(env, "Locale.getDisplayName")) return "English (United States)";
        return jstrToUtf8(env, js);
    }

    bool queryWifiConnected(JNIEnv* env) {
        jclass actCls = env->GetObjectClass(activityGlobal);
        jmethodID getSys = env->GetMethodID(actCls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
        jobject cm = env->CallObjectMethod(activityGlobal, getSys, env->NewStringUTF("connectivity"));
        if (!cm || clearIfException(env, "getSystemService(connectivity)")) return false;
        jclass cmCls = env->GetObjectClass(cm);
        jmethodID getNet = env->GetMethodID(cmCls, "getActiveNetwork", "()Landroid/net/Network;");
        if (clearIfException(env, "getActiveNetwork id")) return false;
        jobject net = env->CallObjectMethod(cm, getNet);
        if (!net || clearIfException(env, "getActiveNetwork call")) return false;
        jmethodID getCaps = env->GetMethodID(cmCls, "getNetworkCapabilities", "(Landroid/net/Network;)Landroid/net/NetworkCapabilities;");
        jobject caps = env->CallObjectMethod(cm, getCaps, net);
        if (!caps || clearIfException(env, "getNetworkCapabilities")) return true;
        jclass capsCls = env->GetObjectClass(caps);
        jmethodID hasCap = env->GetMethodID(capsCls, "hasCapability", "(I)Z");
        jboolean inet = env->CallBooleanMethod(caps, hasCap, (jint)12 /* NET_CAPABILITY_INTERNET */);
        if (clearIfException(env, "hasCapability")) return true;
        return inet == JNI_TRUE;
    }

    bool queryBluetoothEnabled(JNIEnv* env) {
        jclass btCls = env->FindClass("android/bluetooth/BluetoothAdapter");
        if (!btCls || clearIfException(env, "BluetoothAdapter")) return false;
        jmethodID getDef = env->GetStaticMethodID(btCls, "getDefaultAdapter", "()Landroid/bluetooth/BluetoothAdapter;");
        jobject bt = env->CallStaticObjectMethod(btCls, getDef);
        if (!bt || clearIfException(env, "getDefaultAdapter")) return false;
        jmethodID isEn = env->GetMethodID(btCls, "isEnabled", "()Z");
        jboolean en = env->CallBooleanMethod(bt, isEn);
        if (clearIfException(env, "BluetoothAdapter.isEnabled")) return false;
        return en == JNI_TRUE;
    }

    int queryCameraCount(JNIEnv* env) {
        jclass actCls = env->GetObjectClass(activityGlobal);
        jmethodID getSys = env->GetMethodID(actCls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
        jobject camMgr = env->CallObjectMethod(activityGlobal, getSys, env->NewStringUTF("camera"));
        if (!camMgr || clearIfException(env, "getSystemService(camera)")) return 0;
        jclass cmCls = env->GetObjectClass(camMgr);
        jmethodID getIds = env->GetMethodID(cmCls, "getCameraIdList", "()[Ljava/lang/String;");
        jobjectArray arr = (jobjectArray)env->CallObjectMethod(camMgr, getIds);
        if (!arr || clearIfException(env, "getCameraIdList")) return 0;
        return (int)env->GetArrayLength(arr);
    }

    std::string queryInputDevicesSummary(JNIEnv* env) {
        jclass idCls = env->FindClass("android/view/InputDevice");
        if (!idCls || clearIfException(env, "InputDevice")) return "Built-in Laptop Keyboard & Touchpad";
        jmethodID getIds = env->GetStaticMethodID(idCls, "getDeviceIds", "()[I");
        jmethodID getDev = env->GetStaticMethodID(idCls, "getDevice", "(I)Landroid/view/InputDevice;");
        jmethodID getName = env->GetMethodID(idCls, "getName", "()Ljava/lang/String;");
        jmethodID isVirt = env->GetMethodID(idCls, "isVirtual", "()Z");
        jintArray ids = (jintArray)env->CallStaticObjectMethod(idCls, getIds);
        if (!ids || clearIfException(env, "InputDevice.getDeviceIds")) return "Built-in Laptop Keyboard & Touchpad";
        jsize len = env->GetArrayLength(ids);
        std::vector<jint> buf(len);
        if (len > 0) env->GetIntArrayRegion(ids, 0, len, buf.data());
        std::string found;
        int count = 0;
        for (jsize i = 0; i < len && count < 3; ++i) {
            jobject dev = env->CallStaticObjectMethod(idCls, getDev, buf[i]);
            if (!dev || clearIfException(env, "InputDevice.getDevice")) continue;
            if (env->CallBooleanMethod(dev, isVirt) == JNI_TRUE) continue;
            std::string nm = jstrToUtf8(env, (jstring)env->CallObjectMethod(dev, getName));
            if (nm.empty() || nm.find("Power Button") != std::string::npos || nm.find("Video Bus") != std::string::npos ||
                nm.find("Lid Switch") != std::string::npos || nm.find("HDMI") != std::string::npos) continue;
            if (!found.empty()) found += "  •  ";
            found += nm;
            count++;
        }
        return found.empty() ? "Standard Laptop Keyboard & Precision Touchpad" : found;
    }

    void launchIntentAction(JNIEnv* env, const char* primaryAction, const char* fallbackAction = nullptr, bool addGoogleExtra = false) {
        jclass intentCls = env->FindClass("android/content/Intent");
        jmethodID ctor = env->GetMethodID(intentCls, "<init>", "(Ljava/lang/String;)V");
        jmethodID addFlags = env->GetMethodID(intentCls, "addFlags", "(I)Landroid/content/Intent;");
        jclass actCls = env->GetObjectClass(activityGlobal);
        jmethodID startAct = env->GetMethodID(actCls, "startActivity", "(Landroid/content/Intent;)V");

        jobject intent = env->NewObject(intentCls, ctor, env->NewStringUTF(primaryAction));
        env->CallObjectMethod(intent, addFlags, (jint)0x10000000 /* FLAG_ACTIVITY_NEW_TASK */);
        if (addGoogleExtra) {
            jclass strCls = env->FindClass("java/lang/String");
            jobjectArray types = env->NewObjectArray(1, strCls, env->NewStringUTF("com.google"));
            jmethodID putExtra = env->GetMethodID(intentCls, "putExtra", "(Ljava/lang/String;[Ljava/lang/String;)Landroid/content/Intent;");
            env->CallObjectMethod(intent, putExtra, env->NewStringUTF("account_types"), types);
            clearIfException(env, "putExtra account_types");
        }
        env->CallVoidMethod(activityGlobal, startAct, intent);
        if (clearIfException(env, primaryAction) && fallbackAction) {
            jobject fb = env->NewObject(intentCls, ctor, env->NewStringUTF(fallbackAction));
            env->CallObjectMethod(fb, addFlags, (jint)0x10000000);
            env->CallVoidMethod(activityGlobal, startAct, fb);
            clearIfException(env, fallbackAction);
        }
    }

    void playTestTone(JNIEnv* env) {
        jclass tgCls = env->FindClass("android/media/ToneGenerator");
        if (!tgCls || clearIfException(env, "ToneGenerator")) return;
        jmethodID ctor = env->GetMethodID(tgCls, "<init>", "(II)V");
        jmethodID startTone = env->GetMethodID(tgCls, "startTone", "(II)Z");
        jobject tg = env->NewObject(tgCls, ctor, (jint)3 /* STREAM_MUSIC */, (jint)85);
        if (tg && !clearIfException(env, "ToneGenerator.<init>")) {
            env->CallBooleanMethod(tg, startTone, (jint)28 /* TONE_PROP_BEEP2 */, (jint)200);
            clearIfException(env, "ToneGenerator.startTone");
        }
    }

    void writeApplyTrigger(bool completeSetup) {
        mkdir("/data/local/tmp/fidebook_oobe", 0777);
        const char* cfgPath = "/data/local/tmp/fidebook_oobe/config.env";
        FILE* f = fopen(cfgPath, "w");
        if (f) {
            std::string cleanName = sanitizeConfigVal(deviceName);
            if (cleanName.empty()) cleanName = "FideBook";
            fprintf(f, "DEVICE_NAME=\"%s\"\n", cleanName.c_str());
            fprintf(f, "LIQUID_GLASS=%d\n", liquidGlass ? 1 : 0);
            fprintf(f, "MOTION_BLUR=%s\n", motionBlur.c_str());
            fprintf(f, "DARK_MODE=%s\n", darkMode ? "yes" : "no");
            fprintf(f, "DENSITY=%d\n", targetDpi);
            fprintf(f, "TOUCHPAD_FLICK=%d\n", touchpadFlickBoost ? 1 : 0);
            fprintf(f, "COMPLETE=%d\n", completeSetup ? 1 : 0);
            fclose(f);
            chmod(cfgPath, 0666);
        }
        FILE* tr = fopen("/data/local/tmp/fidebook_oobe/apply.trigger", "w");
        if (tr) {
            fprintf(tr, "1\n");
            fclose(tr);
            chmod("/data/local/tmp/fidebook_oobe/apply.trigger", 0666);
        }
    }

    void completeAndLaunchDesktop(JNIEnv* env) {
        captureEditTextIfPresent(env);
        mkdir("/data/local/tmp/fidebook_oobe", 0777);
        if (FILE* df = fopen("/data/local/tmp/fidebook_oobe/done.flag", "w")) {
            fprintf(df, "1\n");
            fclose(df);
            chmod("/data/local/tmp/fidebook_oobe/done.flag", 0666);
        }
        writeApplyTrigger(true);

        // Also store completion in app SharedPreferences
        jclass actCls = env->GetObjectClass(activityGlobal);
        jmethodID getSp = env->GetMethodID(actCls, "getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;");
        jobject sp = env->CallObjectMethod(activityGlobal, getSp, env->NewStringUTF("fidebook_oobe"), (jint)0);
        if (sp && !clearIfException(env, "getSharedPreferences")) {
            jclass spCls = env->GetObjectClass(sp);
            jmethodID editMid = env->GetMethodID(spCls, "edit", "()Landroid/content/SharedPreferences$Editor;");
            jobject ed = env->CallObjectMethod(sp, editMid);
            if (ed && !clearIfException(env, "SharedPreferences.edit")) {
                jclass edCls = env->GetObjectClass(ed);
                jmethodID putBool = env->GetMethodID(edCls, "putBoolean", "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;");
                jmethodID applyMid = env->GetMethodID(edCls, "apply", "()V");
                env->CallObjectMethod(ed, putBool, env->NewStringUTF("completed"), JNI_TRUE);
                env->CallVoidMethod(ed, applyMid);
                clearIfException(env, "SharedPreferences.apply");
            }
        }

        // Launch FideBookOS Desktop Home
        jclass intentCls = env->FindClass("android/content/Intent");
        jmethodID ctor = env->GetMethodID(intentCls, "<init>", "(Ljava/lang/String;)V");
        jmethodID addCat = env->GetMethodID(intentCls, "addCategory", "(Ljava/lang/String;)Landroid/content/Intent;");
        jmethodID addFlags = env->GetMethodID(intentCls, "addFlags", "(I)Landroid/content/Intent;");
        jobject home = env->NewObject(intentCls, ctor, env->NewStringUTF("android.intent.action.MAIN"));
        env->CallObjectMethod(home, addCat, env->NewStringUTF("android.intent.category.HOME"));
        env->CallObjectMethod(home, addFlags, (jint)0x10000000);
        jmethodID startAct = env->GetMethodID(actCls, "startActivity", "(Landroid/content/Intent;)V");
        env->CallVoidMethod(activityGlobal, startAct, home);
        clearIfException(env, "startActivity HOME");

        jmethodID finishMid = env->GetMethodID(actCls, "finish", "()V");
        env->CallVoidMethod(activityGlobal, finishMid);
    }

    void buildStepContent(JNIEnv* env, jobject body) {
        const M3Palette& p = pal();

        if (step == 0) {
            addView(env, body, makeText(env, "Built for Desktop Performance", 17.0f, p.onSurface, true),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(12)));
            addView(env, body, makeOptionCard(env,
                    "Material 3 Desktop & Freeform Windows",
                    "Multi-window multitasking, Google-gradient \"F\" dock, and desktop keyboard shortcuts.",
                    false, 0, "Ready"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));
            addView(env, body, makeOptionCard(env,
                    "Liquid Glass + Vulkan 1.4 Motion Blur",
                    "Real-time optical background refraction on Taskbar, Control Center & App Menu plus 60 FPS scroll blur.",
                    false, 0, "1.25 New"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            addView(env, body, makeText(env, "Language & Accessibility", 14.0f, p.onSurfaceVariant, true),
                    makeLP(env, -1, -2, 0.0f, 0, dp(4), 0, dp(8)));
            addView(env, body, makeOptionCard(env,
                    "System Language: " + queryLocaleDisplay(env),
                    "Tap to choose your preferred language and regional format.",
                    false, ACT_LANG, "Change"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));
            addView(env, body, makeOptionCard(env,
                    "Accessibility Options",
                    "Screen reader (TalkBack), display magnification, captions, and high-contrast text.",
                    false, ACT_A11Y, "Configure"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
        } else if (step == 1) {
            bool wifiOk = queryWifiConnected(env);
            bool btOk = queryBluetoothEnabled(env);

            jobject statusBanner = makeLinear(env, false);
            setPadding(env, statusBanner, dp(16), dp(12), dp(16), dp(12));
            setViewBg(env, statusBanner, makeRoundedDrawable(env, wifiOk ? p.successBg : p.warnBg, 16.0f));
            addView(env, statusBanner, makeText(env,
                    wifiOk ? "Connected to Wi-Fi — Internet connection is active."
                           : "Not connected yet — Choose a Wi-Fi network below or continue offline.",
                    13.0f, wifiOk ? p.successFg : p.warnFg, true),
                    makeLP(env, 0, -2, 1.0f));
            addView(env, body, statusBanner, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            addView(env, body, makeOptionCard(env,
                    "Wi-Fi Networks",
                    "Open the Material 3 Wi-Fi panel to join your home, school, or hotspot network.",
                    wifiOk, ACT_WIFI, wifiOk ? "Connected" : "Select Wi-Fi"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));

            addView(env, body, makeOptionCard(env,
                    "Bluetooth Accessories",
                    btOk ? "Bluetooth controller is powered on and ready to pair headphones, mice, or controllers."
                         : "Open Bluetooth settings to enable wireless audio and accessories.",
                    btOk, ACT_BT, btOk ? "Controller On" : "Open"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(12)));

            jobject refreshRow = makeLinear(env, false);
            addView(env, refreshRow, makeTonalButton(env, "Refresh Connection Status", ACT_REFRESH_NET),
                    makeLP(env, -2, -2));
            addView(env, body, refreshRow, makeLP(env, -1, -2, 0.0f, 0, dp(2), 0, 0));
        } else if (step == 2) {
            std::string inputs = queryInputDevicesSummary(env);
            addView(env, body, makeOptionCard(env,
                    "Detected Input Hardware",
                    inputs,
                    true, 0, "Active"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(12)));

            addView(env, body, makeOptionCard(env,
                    "Low-Latency Touchpad Flick Boost (20ms)",
                    "Eliminates the 200ms gesture hold delay on laptop precision touchpads for instant cursor movement.",
                    touchpadFlickBoost, ACT_TP_FLICK_TOGGLE, touchpadFlickBoost ? "Enabled" : "Off"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));

            addView(env, body, makeOptionCard(env,
                    "Physical Keyboard Layout & Shortcuts",
                    "Customize keyboard layout, Alt+Tab switching, and multi-language typing.",
                    false, ACT_KB_SETTINGS, "Customize"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
        } else if (step == 3) {
            // Laptop Name EditText
            addView(env, body, makeText(env, "Laptop Device Name", 13.5f, p.onSurfaceVariant, true),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));

            jclass etCls = env->FindClass("android/widget/EditText");
            jmethodID etCtor = env->GetMethodID(etCls, "<init>", "(Landroid/content/Context;)V");
            jobject et = env->NewObject(etCls, etCtor, activityGlobal);
            env->CallVoidMethod(et, env->GetMethodID(etCls, "setText", "(Ljava/lang/CharSequence;)V"),
                                env->NewStringUTF(deviceName.c_str()));
            env->CallVoidMethod(et, env->GetMethodID(etCls, "setTextColor", "(I)V"), p.onSurface);
            env->CallVoidMethod(et, env->GetMethodID(etCls, "setHintTextColor", "(I)V"), p.onSurfaceVariant);
            env->CallVoidMethod(et, env->GetMethodID(etCls, "setHint", "(Ljava/lang/CharSequence;)V"),
                                env->NewStringUTF("FideBook"));
            env->CallVoidMethod(et, env->GetMethodID(etCls, "setSingleLine", "(Z)V"), JNI_TRUE);
            env->CallVoidMethod(et, env->GetMethodID(etCls, "setTextSize", "(IF)V"), (jint)2, 15.0f);
            setPadding(env, et, dp(16), dp(12), dp(16), dp(12));
            setViewBg(env, et, makeRoundedDrawable(env, p.surfaceCard, 14.0f, dp(1), p.primary));
            clearNameEditRef(env);
            nameEditGlobal = env->NewGlobalRef(et);
            addView(env, body, et, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            // Theme selector row
            addView(env, body, makeText(env, "Material 3 Appearance Theme", 13.5f, p.onSurfaceVariant, true),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
            jobject themeRow = makeLinear(env, false);
            addView(env, themeRow, makeOptionCard(env, "Dark Obsidian", "Deep contrast", darkMode, ACT_THEME_DARK),
                    makeLP(env, 0, -2, 1.0f, 0, 0, dp(6), 0));
            addView(env, themeRow, makeOptionCard(env, "Light Daylight", "Crisp & bright", !darkMode, ACT_THEME_LIGHT),
                    makeLP(env, 0, -2, 1.0f, dp(6), 0, 0, 0));
            addView(env, body, themeRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            // Liquid Glass refraction selector
            addView(env, body, makeText(env, "Liquid Glass Background Refraction", 13.5f, p.onSurfaceVariant, true),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
            jobject glassRow = makeLinear(env, false);
            addView(env, glassRow, makeOptionCard(env, "Liquid Glass On", "Taskbar, Control Center & App Menu", liquidGlass, ACT_GLASS_ON),
                    makeLP(env, 0, -2, 1.0f, 0, 0, dp(6), 0));
            addView(env, glassRow, makeOptionCard(env, "Standard M3", "Classic solid panels", !liquidGlass, ACT_GLASS_OFF),
                    makeLP(env, 0, -2, 1.0f, dp(6), 0, 0, 0));
            addView(env, body, glassRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            // GPU Scroll Motion Blur selector
            addView(env, body, makeText(env, "Hardware GPU Scroll Motion Blur", 13.5f, p.onSurfaceVariant, true),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
            addView(env, body, makeOptionCard(env,
                    "UI Scroll Motion Blur (Recommended)",
                    "60 FPS directional shutter blur when scrolling App Menu, Settings & Control Center.",
                    motionBlur == "ui", ACT_MBLUR_UI),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
            addView(env, body, makeOptionCard(env,
                    "Everywhere (Apps + Games)",
                    "Applies real-time directional motion blur to all scrolling views and games.",
                    motionBlur == "all", ACT_MBLUR_ALL),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));
            addView(env, body, makeOptionCard(env,
                    "Off",
                    "Standard unblurred frames.",
                    motionBlur == "off", ACT_MBLUR_OFF),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            // Display Scale Chips
            addView(env, body, makeText(env, "Desktop Display Scaling", 13.5f, p.onSurfaceVariant, true),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
            jobject dpiRow = makeLinear(env, false);
            struct DpiOpt { int dpi; const char* lbl; int act; } dpis[4] = {
                {140, "Compact", ACT_DPI_140},
                {160, "Balanced", ACT_DPI_160},
                {180, "Comfort", ACT_DPI_180},
                {200, "Large", ACT_DPI_200},
            };
            for (int i = 0; i < 4; ++i) {
                bool sel = (targetDpi == dpis[i].dpi);
                jobject chip = makeLinear(env, false);
                env->CallVoidMethod(chip, env->GetMethodID(env->FindClass("android/widget/LinearLayout"), "setGravity", "(I)V"), 17);
                setPadding(env, chip, dp(10), dp(10), dp(10), dp(10));
                setViewBg(env, chip, makeRippleSurface(env, sel ? p.surfaceCardSelected : p.surfaceCard,
                          14.0f, p.rippleOnSurface, sel ? dp(2) : dp(1), sel ? p.primary : p.outlineVariant));
                attachAction(env, chip, dpis[i].act);
                addView(env, chip, makeText(env, dpis[i].lbl, 12.5f, sel ? p.primary : p.onSurface, true, 1.0f),
                        makeLP(env, -2, -2));
                addView(env, dpiRow, chip, makeLP(env, 0, -2, 1.0f, i == 0 ? 0 : dp(4), 0, i == 3 ? 0 : dp(4), 0));
            }
            addView(env, body, dpiRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(4)));
        } else if (step == 4) {
            std::string gpuMode = getSysProp(env, "ro.fidebook.gpu_mode", "intel-vulkan");
            std::string gpuDesc = (gpuMode == "radv")
                ? "AMD Radeon Hardware Vulkan 1.4 (Multi-Queue RADV + GPU Motion Blur)"
                : (gpuMode == "swiftshader" ? "CPU Vulkan Fallback (SwiftShader)"
                                            : "Intel Integrated Hardware Vulkan 1.4");
            int cams = queryCameraCount(env);
            char camBuf[128];
            snprintf(camBuf, sizeof(camBuf),
                     cams > 0 ? "%d internal camera(s) ready — Tap to test your laptop webcam."
                              : "Tap to open Camera and verify video capture.", cams);

            addView(env, body, makeOptionCard(env,
                    "Graphics & Display Engine",
                    gpuDesc,
                    true, 0, "Verified"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));

            addView(env, body, makeOptionCard(env,
                    "Built-in Laptop HD Camera",
                    camBuf,
                    cams > 0, ACT_TEST_CAMERA, cams > 0 ? "Test Camera" : "Open Camera"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));

            addView(env, body, makeOptionCard(env,
                    "Laptop Stereo Speakers & Audio",
                    "Tap to play a short verification chime through your speakers or headphones.",
                    true, ACT_TEST_SOUND, "Play Chime"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(6)));
        } else if (step == 5) {
            addView(env, body, makeOptionCard(env,
                    "Sign in to Google Account (Optional)",
                    "Sync Google Play Store, Chrome, YouTube, Drive, and contacts now or anytime in Settings.",
                    false, ACT_GOOGLE_SIGNIN, "Sign In"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(14)));

            std::string mbName = (motionBlur == "ui") ? "UI Scroll Motion Blur (60 FPS)"
                               : (motionBlur == "all" ? "Full System Shutter Blur" : "Off");
            char sumBuf[448];
            snprintf(sumBuf, sizeof(sumBuf),
                     "Laptop Name: %s\nAppearance: Material 3 %s\nLiquid Glass: %s\nMotion Blur: %s\nDisplay Scaling: %d DPI",
                     deviceName.c_str(),
                     darkMode ? "Dark Obsidian" : "Light Daylight",
                     liquidGlass ? "Enabled (Taskbar, Control Center & App Menu)" : "Off",
                     mbName.c_str(),
                     targetDpi);

            addView(env, body, makeOptionCard(env,
                    "Your FideBookOS Configuration",
                    sumBuf,
                    true, 0, "Ready"),
                    makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(10)));
        }
    }

    void rebuildUi(JNIEnv* env, bool animateStep) {
        if (env->PushLocalFrame(256) < 0) return;

        clearNameEditRef(env);
        const M3Palette& p = pal();

        // Update Window system bar colors
        jclass actCls = env->GetObjectClass(activityGlobal);
        jmethodID getWin = env->GetMethodID(actCls, "getWindow", "()Landroid/view/Window;");
        jobject win = env->CallObjectMethod(activityGlobal, getWin);
        if (win && !clearIfException(env, "getWindow")) {
            jclass winCls = env->GetObjectClass(win);
            env->CallVoidMethod(win, env->GetMethodID(winCls, "setStatusBarColor", "(I)V"), p.bgCanvas);
            env->CallVoidMethod(win, env->GetMethodID(winCls, "setNavigationBarColor", "(I)V"), p.bgCanvas);
            clearIfException(env, "setBarColors");
        }

        // Fullscreen outer canvas
        jobject root = makeLinear(env, true);
        jclass llCls = env->FindClass("android/widget/LinearLayout");
        jmethodID setGrav = env->GetMethodID(llCls, "setGravity", "(I)V");
        env->CallVoidMethod(root, setGrav, 17 /* Gravity.CENTER */);
        setViewBg(env, root, makeRoundedDrawable(env, p.bgCanvas, 0.0f));
        setPadding(env, root, dp(24), dp(20), dp(24), dp(20));

        // Elevated M3 Setup Shell Card (max ~960dp x 580dp)
        jobject shell = makeLinear(env, true);
        setViewBg(env, shell, makeRoundedDrawable(env, p.surfaceShell, 28.0f, dp(1), p.outlineVariant));
        setElevation(env, shell, 16.0f);
        setClipToOutline(env, shell, true);

        // 4-color Google gradient top bar across shell
        jobject gradBar = makeLinear(env, false);
        setViewBg(env, gradBar, makeGoogleGradientBar(env));
        addView(env, shell, gradBar, makeLP(env, -1, dp(4)));

        // Two-pane horizontal container inside shell
        jobject panes = makeLinear(env, false);
        setPadding(env, panes, dp(16), dp(16), dp(20), dp(16));

        // --- Left Hero Pane (37% width) ---
        static const char* kStepTitles[6] = {
            "Welcome to\nFideBookOS",
            "Connect to\nWi-Fi & Wireless",
            "Keyboard &\nPrecision Touchpad",
            "Personalize\nYour FideBook",
            "Hardware &\nCamera Check",
            "All Set for\nDesktop"
        };
        static const char* kStepSubs[6] = {
            "Fast, fluid Material 3 desktop computing engineered for your laptop.",
            "Join a Wi-Fi network and connect your wireless headphones or mouse.",
            "Fine-tune physical keyboard shortcuts and instant touchpad response.",
            "Choose your laptop name, Material 3 theme, and GPU scroll motion blur.",
            "Verify your graphics engine, built-in laptop HD webcam, and speakers.",
            "Optionally sign in to Google Play and launch your new FideBookOS desktop."
        };

        jobject leftPane = makeLinear(env, true);
        setViewBg(env, leftPane, makeRoundedDrawable(env, p.surfaceHero, 22.0f, dp(1), p.outlineVariant));
        setPadding(env, leftPane, dp(24), dp(24), dp(24), dp(22));

        // Brand row: Google-gradient "F" Logo + FideBookOS 1.0 pill
        jobject brandRow = makeLinear(env, false);
        env->CallVoidMethod(brandRow, setGrav, 16 /* CENTER_VERTICAL */);
        addView(env, brandRow, makeLogoView(env, 48), makeLP(env, dp(48), dp(48), 0.0f, 0, 0, dp(12), 0));
        jobject verPill = makeLinear(env, false);
        setPadding(env, verPill, dp(12), dp(5), dp(12), dp(5));
        setViewBg(env, verPill, makeRoundedDrawable(env, p.secondaryContainer, 14.0f));
        addView(env, verPill, makeText(env, "FideBookOS 1.25", 12.0f, p.onSecondaryContainer, true, 1.0f),
                makeLP(env, -2, -2));
        addView(env, brandRow, verPill, makeLP(env, -2, -2));
        addView(env, leftPane, brandRow, makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(22)));

        // Step headline + subtitle
        addView(env, leftPane, makeText(env, kStepTitles[step], 26.0f, p.onSurface, true, 1.15f),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(12)));
        addView(env, leftPane, makeText(env, kStepSubs[step], 13.5f, p.onSurfaceVariant, false, 1.4f),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(16)));

        // Spacer pushing step progress pills to bottom of hero pane
        addView(env, leftPane, makeLinear(env, true), makeLP(env, -1, 0, 1.0f));

        // Step X of 6 label + Material 3 pill progress indicator
        char stepLbl[32];
        snprintf(stepLbl, sizeof(stepLbl), "Step %d of 6", step + 1);
        addView(env, leftPane, makeText(env, stepLbl, 12.0f, p.onSurfaceVariant, true, 1.0f),
                makeLP(env, -1, -2, 0.0f, 0, 0, 0, dp(8)));

        jobject dotsRow = makeLinear(env, false);
        for (int i = 0; i < 6; ++i) {
            jobject dot = makeLinear(env, false);
            int w = (i == step) ? dp(28) : (i < step ? dp(16) : dp(10));
            jint col = (i <= step) ? p.primary : p.outlineVariant;
            setViewBg(env, dot, makeRoundedDrawable(env, col, 4.0f));
            addView(env, dotsRow, dot, makeLP(env, w, dp(7), 0.0f, 0, 0, dp(6), 0));
        }
        addView(env, leftPane, dotsRow, makeLP(env, -1, -2));

        addView(env, panes, leftPane, makeLP(env, 0, -1, 0.37f, 0, 0, dp(16), 0));

        // --- Right Interactive Content Pane (63% width) ---
        jobject rightPane = makeLinear(env, true);
        setPadding(env, rightPane, dp(6), dp(8), dp(6), dp(4));

        // Scrollable step content area
        jclass svCls = env->FindClass("android/widget/ScrollView");
        jobject scroll = env->NewObject(svCls, env->GetMethodID(svCls, "<init>", "(Landroid/content/Context;)V"), activityGlobal);
        env->CallVoidMethod(scroll, env->GetMethodID(svCls, "setFillViewport", "(Z)V"), JNI_TRUE);
        env->CallVoidMethod(scroll, env->GetMethodID(env->FindClass("android/view/View"), "setVerticalScrollBarEnabled", "(Z)V"), JNI_FALSE);

        jobject body = makeLinear(env, true);
        setPadding(env, body, dp(4), dp(4), dp(4), dp(12));
        buildStepContent(env, body);
        addView(env, scroll, body, makeLP(env, -1, -2));
        addView(env, rightPane, scroll, makeLP(env, -1, 0, 1.0f));

        // Smooth Material 3 step slide+fade transition
        if (animateStep) {
            jclass vCls = env->FindClass("android/view/View");
            env->CallVoidMethod(body, env->GetMethodID(vCls, "setAlpha", "(F)V"), 0.12f);
            env->CallVoidMethod(body, env->GetMethodID(vCls, "setTranslationX", "(F)V"), (float)dp(lastStepDir * 22));
            jobject vpa = env->CallObjectMethod(body, env->GetMethodID(vCls, "animate", "()Landroid/view/ViewPropertyAnimator;"));
            if (vpa && !clearIfException(env, "View.animate")) {
                jclass vpaCls = env->GetObjectClass(vpa);
                env->CallObjectMethod(vpa, env->GetMethodID(vpaCls, "alpha", "(F)Landroid/view/ViewPropertyAnimator;"), 1.0f);
                env->CallObjectMethod(vpa, env->GetMethodID(vpaCls, "translationX", "(F)Landroid/view/ViewPropertyAnimator;"), 0.0f);
                env->CallObjectMethod(vpa, env->GetMethodID(vpaCls, "setDuration", "(J)Landroid/view/ViewPropertyAnimator;"), (jlong)210);
                env->CallVoidMethod(vpa, env->GetMethodID(vpaCls, "start", "()V"));
                clearIfException(env, "ViewPropertyAnimator.start");
            }
        }

        // Bottom M3 Navigation Bar
        jobject navBar = makeLinear(env, false);
        env->CallVoidMethod(navBar, setGrav, 16 /* CENTER_VERTICAL */);
        setPadding(env, navBar, dp(4), dp(12), dp(4), dp(4));

        if (step > 0) {
            addView(env, navBar, makePillButton(env, "Back", ACT_BACK, false), makeLP(env, -2, -2));
        } else {
            addView(env, navBar, makeTonalButton(env, "Skip Setup", ACT_SKIP), makeLP(env, -2, -2));
        }

        addView(env, navBar, makeLinear(env, false), makeLP(env, 0, dp(1), 1.0f));

        if (step < 5) {
            const char* nextLbl = (step == 0) ? "Get Started" : "Continue";
            addView(env, navBar, makePillButton(env, nextLbl, ACT_NEXT, true), makeLP(env, -2, -2));
        } else {
            addView(env, navBar, makePillButton(env, "Start Using FideBookOS", ACT_FINISH, true), makeLP(env, -2, -2));
        }

        addView(env, rightPane, navBar, makeLP(env, -1, -2));
        addView(env, panes, rightPane, makeLP(env, 0, -1, 0.63f));
        addView(env, shell, panes, makeLP(env, -1, 0, 1.0f));

        int shellW = dp(960);
        int shellH = dp(575);
        // Adapt gracefully to smaller 1366x768 laptop panels if needed
        jobject res = env->CallObjectMethod(activityGlobal, env->GetMethodID(actCls, "getResources", "()Landroid/content/res/Resources;"));
        if (res && !clearIfException(env, "res")) {
            jobject dm = env->CallObjectMethod(res, env->GetMethodID(env->GetObjectClass(res), "getDisplayMetrics", "()Landroid/util/DisplayMetrics;"));
            if (dm && !clearIfException(env, "dm")) {
                jclass dmCls = env->GetObjectClass(dm);
                int wPx = env->GetIntField(dm, env->GetFieldID(dmCls, "widthPixels", "I"));
                int hPx = env->GetIntField(dm, env->GetFieldID(dmCls, "heightPixels", "I"));
                if (wPx > 0 && shellW > wPx - dp(40)) shellW = wPx - dp(40);
                if (hPx > 0 && shellH > hPx - dp(36)) shellH = hPx - dp(36);
            }
        }
        addView(env, root, shell, makeLP(env, shellW, shellH));

        jmethodID setCv = env->GetMethodID(actCls, "setContentView", "(Landroid/view/View;)V");
        env->CallVoidMethod(activityGlobal, setCv, root);
        clearIfException(env, "setContentView");

        env->PopLocalFrame(nullptr);
    }

    void handleAction(JNIEnv* env, int actionId) {
        captureEditTextIfPresent(env);
        switch (actionId) {
            case ACT_NEXT:
                if (step < 5) {
                    step++;
                    lastStepDir = 1;
                    writeApplyTrigger(false);
                    rebuildUi(env, true);
                }
                break;
            case ACT_BACK:
                if (step > 0) {
                    step--;
                    lastStepDir = -1;
                    rebuildUi(env, true);
                }
                break;
            case ACT_SKIP:
            case ACT_FINISH:
                completeAndLaunchDesktop(env);
                break;
            case ACT_LANG:
                launchIntentAction(env, "android.settings.LOCALE_SETTINGS", "android.settings.SETTINGS");
                break;
            case ACT_A11Y:
                launchIntentAction(env, "android.settings.ACCESSIBILITY_SETTINGS", "android.settings.SETTINGS");
                break;
            case ACT_WIFI:
                launchIntentAction(env, "android.settings.panel.action.WIFI", "android.settings.WIFI_SETTINGS");
                break;
            case ACT_BT:
                launchIntentAction(env, "android.settings.BLUETOOTH_SETTINGS", "android.settings.SETTINGS");
                break;
            case ACT_REFRESH_NET:
                rebuildUi(env, false);
                break;
            case ACT_KB_SETTINGS:
                launchIntentAction(env, "android.settings.HARD_KEYBOARD_SETTINGS", "android.settings.INPUT_METHOD_SETTINGS");
                break;
            case ACT_TP_FLICK_TOGGLE:
                touchpadFlickBoost = !touchpadFlickBoost;
                rebuildUi(env, false);
                break;
            case ACT_THEME_DARK:
                darkMode = true;
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_THEME_LIGHT:
                darkMode = false;
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_GLASS_ON:
                liquidGlass = true;
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_GLASS_OFF:
                liquidGlass = false;
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_MBLUR_UI:
                motionBlur = "ui";
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_MBLUR_ALL:
                motionBlur = "all";
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_MBLUR_OFF:
                motionBlur = "off";
                writeApplyTrigger(false);
                rebuildUi(env, false);
                break;
            case ACT_DPI_140: targetDpi = 140; rebuildUi(env, false); break;
            case ACT_DPI_160: targetDpi = 160; rebuildUi(env, false); break;
            case ACT_DPI_180: targetDpi = 180; rebuildUi(env, false); break;
            case ACT_DPI_200: targetDpi = 200; rebuildUi(env, false); break;
            case ACT_TEST_CAMERA:
                launchIntentAction(env, "android.media.action.STILL_IMAGE_CAMERA", "android.media.action.IMAGE_CAPTURE");
                break;
            case ACT_TEST_SOUND:
                playTestTone(env);
                break;
            case ACT_GOOGLE_SIGNIN:
                launchIntentAction(env, "android.settings.ADD_ACCOUNT_SETTINGS", "android.settings.SYNC_SETTINGS", true);
                break;
            default:
                break;
        }
    }
};

static SetupState* getPtr(JNIEnv* env, jobject thiz) {
    jclass cls = env->GetObjectClass(thiz);
    jfieldID fid = env->GetFieldID(cls, "nativePtr", "J");
    return reinterpret_cast<SetupState*>(env->GetLongField(thiz, fid));
}

static void setPtr(JNIEnv* env, jobject thiz, SetupState* st) {
    jclass cls = env->GetObjectClass(thiz);
    jfieldID fid = env->GetFieldID(cls, "nativePtr", "J");
    env->SetLongField(thiz, fid, reinterpret_cast<jlong>(st));
}

} // namespace

extern "C" {

JNIEXPORT void JNICALL
Java_org_fidebookos_setup_SetupActivity_nativeOnCreate(JNIEnv* env, jobject thiz, jobject /*savedInstanceState*/) {
    jclass actCls = env->GetObjectClass(thiz);

    // Guard: never run again if first-boot setup was already completed
    struct stat sb{};
    bool alreadyDone = (getSysProp(env, "persist.sys.fidebook.oobe_done", "0") == "1") ||
                       (stat("/data/local/tmp/.fidebook_oobe_done", &sb) == 0) ||
                       (stat("/data/local/tmp/fidebook_oobe/done.flag", &sb) == 0);
    if (!alreadyDone) {
        jmethodID getSp = env->GetMethodID(actCls, "getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;");
        jobject sp = env->CallObjectMethod(thiz, getSp, env->NewStringUTF("fidebook_oobe"), (jint)0);
        if (sp && !clearIfException(env, "getSharedPreferences check")) {
            jclass spCls = env->GetObjectClass(sp);
            jmethodID getBool = env->GetMethodID(spCls, "getBoolean", "(Ljava/lang/String;Z)Z");
            if (env->CallBooleanMethod(sp, getBool, env->NewStringUTF("completed"), JNI_FALSE) == JNI_TRUE) {
                alreadyDone = true;
            }
            clearIfException(env, "getBoolean completed");
        }
    }
    if (alreadyDone) {
        LOGI("FideBookOS Setup already completed on first boot; closing immediately");
        env->CallVoidMethod(thiz, env->GetMethodID(actCls, "finish", "()V"));
        return;
    }

    LOGI("FideBookOS Material 3 Setup Wizard starting (first boot)");
    mkdir("/data/local/tmp/fidebook_oobe", 0777);
    if (FILE* sf = fopen("/data/local/tmp/fidebook_oobe/started.flag", "w")) {
        fprintf(sf, "1\n");
        fclose(sf);
        chmod("/data/local/tmp/fidebook_oobe/started.flag", 0666);
    }

    // Request no title bar before setContentView
    jmethodID reqFeat = env->GetMethodID(actCls, "requestWindowFeature", "(I)Z");
    env->CallBooleanMethod(thiz, reqFeat, (jint)1 /* Window.FEATURE_NO_TITLE */);
    clearIfException(env, "requestWindowFeature");

    jobject win = env->CallObjectMethod(thiz, env->GetMethodID(actCls, "getWindow", "()Landroid/view/Window;"));
    if (win && !clearIfException(env, "getWindow onCreate")) {
        jclass winCls = env->GetObjectClass(win);
        env->CallVoidMethod(win, env->GetMethodID(winCls, "setSoftInputMode", "(I)V"), (jint)16 /* SOFT_INPUT_ADJUST_RESIZE */);
        clearIfException(env, "setSoftInputMode");
    }

    auto* st = new SetupState();
    st->activityGlobal = env->NewGlobalRef(thiz);
    st->initFromSystem(env, thiz);
    setPtr(env, thiz, st);
    st->rebuildUi(env, true);
}

JNIEXPORT void JNICALL
Java_org_fidebookos_setup_SetupActivity_nativeOnResume(JNIEnv* env, jobject thiz) {
    if (auto* st = getPtr(env, thiz)) {
        // Refresh live Wi-Fi / Bluetooth / Locale / Camera status when returning from Settings sheets
        if (st->step != 3) {
            st->rebuildUi(env, false);
        }
    }
}

JNIEXPORT void JNICALL
Java_org_fidebookos_setup_SetupActivity_nativeOnBack(JNIEnv* env, jobject thiz) {
    if (auto* st = getPtr(env, thiz)) {
        if (st->step > 0) {
            st->handleAction(env, ACT_BACK);
        }
        // On Step 0, keep the user inside Setup unless they explicitly tap Skip Setup or finish
    }
}

JNIEXPORT void JNICALL
Java_org_fidebookos_setup_SetupActivity_nativeOnAction(JNIEnv* env, jobject thiz, jint actionId, jobject /*view*/) {
    if (auto* st = getPtr(env, thiz)) {
        st->handleAction(env, (int)actionId);
    }
}

JNIEXPORT void JNICALL
Java_org_fidebookos_setup_SetupActivity_nativeOnDestroy(JNIEnv* env, jobject thiz) {
    if (auto* st = getPtr(env, thiz)) {
        st->clearNameEditRef(env);
        if (st->activityGlobal) {
            env->DeleteGlobalRef(st->activityGlobal);
            st->activityGlobal = nullptr;
        }
        setPtr(env, thiz, nullptr);
        delete st;
    }
}

} // extern "C"
