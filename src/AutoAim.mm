#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <cmath>

// ============ CONFIG ============
static float FOV        = 210.f;   // radio en px desde el centro
static float SMOOTH     = 2.2f;    // 1 = pegajoso, 10 = suave
static bool  AIM_HEAD   = true;    // false = pecho
// ================================

static bool g_on = false;

// ---- il2cpp ----
typedef void* (*f_dom)();
typedef void* (*f_asms)(void*, size_t*);
typedef void* (*f_img)(void*);
typedef void* (*f_cls)(void*, const char*, const char*);
typedef void* (*f_mth)(void*, const char*, int);
typedef void* (*f_ptr)(void*);

static f_dom  p_dom;  static f_asms p_asms; static f_img p_img;
static f_cls  p_cls;  static f_mth  p_mth;  static f_ptr p_ptr;

static void Resolve(void) {
    void* h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW);
    if (!h) return;
    p_dom  = (f_dom)dlsym(h, "il2cpp_domain_get");
    p_asms = (f_asms)dlsym(h, "il2cpp_domain_get_assemblies");
    p_img  = (f_img)dlsym(h, "il2cpp_assembly_get_image");
    p_cls  = (f_cls)dlsym(h, "il2cpp_class_from_name");
    p_mth  = (f_mth)dlsym(h, "il2cpp_class_get_method_from_name");
    p_ptr  = (f_ptr)dlsym(h, "il2cpp_method_get_pointer");
}

static void* FindClass(const char* n) {
    if (!p_dom) return nullptr;
    size_t c = 0;
    void** a = (void**)p_asms(p_dom(), &c);
    if (!a) return nullptr;
    for (size_t i = 0; i < c; i++) {
        void* k = p_cls(p_img(a[i]), "", n);
        if (k) return k;
    }
    return nullptr;
}

static uintptr_t FindMethod(const char* cls, const char* mth, int argc) {
    void* k = FindClass(cls);
    if (!k) return 0;
    void* m = p_mth(k, mth, argc);
    return m ? (uintptr_t)p_ptr(m) : 0;
}

// ---- estructuras ----
struct V3 { float x, y, z; };

static void* GetLocalPlayer(void) {
    void* gf = FindClass("GameFacade");
    if (!gf) return nullptr;
    void* m = p_mth(gf, "get_LocalPlayer", 0);
    if (!m) return nullptr;
    return ((void*(*)())(p_ptr(m)))();
}

// jugador enemigo más cercano al centro de pantalla
static void* BestTarget(void* local, float sw, float sh) {
    void* pm = nullptr;
    void* gf = FindClass("GameFacade");
    if (gf) {
        void* m = p_mth(gf, "get_PlayerManager", 0);
        if (m) pm = ((void*(*)())(p_ptr(m)))();
    }
    if (!pm) return nullptr;

    void* kPM = *(void**)pm;
    void* mList = p_mth(kPM, "get_Players", 0);
    if (!mList) return nullptr;
    void* list = ((void*(*)(void*))(p_ptr(mList)))(pm);
    if (!list) return nullptr;

    void* kL = *(void**)list;
    void* mItem = p_mth(kL, "get_Item", 1);
    if (!mItem) return nullptr;
    auto item = (void*(*)(void*, int))(p_ptr(mItem));
    int size = *(int*)((uintptr_t)list + 0x18);
    if (size <= 0 || size > 100) return nullptr;

    void* kP = FindClass("Player");
    if (!kP) return nullptr;
    void* mPos  = p_mth(kP, "get_Position", 0);
    void* mLoc  = p_mth(kP, "get_IsLocal", 0);
    void* mTeam = p_mth(kP, "get_Team", 0);
    if (!mPos || !mLoc || !mTeam) return nullptr;

    auto getPos  = (V3(*)(void*))(p_ptr(mPos));
    auto isLocal = (bool(*)(void*))(p_ptr(mLoc));
    auto getTeam = (int(*)(void*))(p_ptr(mTeam));
    int myTeam = getTeam(local);

    void* best = nullptr;
    float bestD = FOV;
    for (int i = 0; i < size; i++) {
        void* p = item(list, i);
        if (!p || isLocal(p) || getTeam(p) == myTeam) continue;

        V3 pos = getPos(p);
        // distancia aproximada al centro en pantalla: usamos magnitud 2D proyectada
        V3 d = { pos.x, pos.y + (AIM_HEAD ? 1.75f : 1.15f), pos.z };
        V3 l = getPos(local);
        float dx = d.x - l.x, dy = d.y - l.y, dz = d.z - l.z;
        float dist = sqrtf(dx*dx + dy*dy + dz*dz);
        if (dist > 400.f) continue;

        // score simple: distancia 3D normalizada (suficiente para apuntar)
        if (dist < bestD) { bestD = dist; best = p; }
    }
    return best;
}

// ---- hook de apuntado ----
typedef void (*Aim_t)(void*, float, float, bool);
static Aim_t origAim = nullptr;
static void* g_target = nullptr;

static void HookAim(void* self, float pitch, float yaw, bool force) {
    if (g_on && self && g_target) {
        void* local = GetLocalPlayer();
        void* kP = FindClass("Player");
        if (local && kP) {
            void* mPos = p_mth(kP, "get_Position", 0);
            if (mPos) {
                auto getPos = (V3(*)(void*))(p_ptr(mPos));
                V3 l = getPos(local);
                V3 t = getPos(g_target);
                t.y += AIM_HEAD ? 1.75f : 1.15f;

                float dx = t.x - l.x, dy = t.y - l.y, dz = t.z - l.z;
                float hyp = sqrtf(dx*dx + dz*dz);
                float tp = atan2f(dy, hyp) * 57.29578f;
                float ty = atan2f(dx, dz) * 57.29578f;

                float f = 1.f / (SMOOTH <= 1.f ? 1.f : SMOOTH);
                pitch += (tp - pitch) * f;
                yaw   += (ty - yaw)   * f;
            }
        }
    }
    origAim(self, pitch, yaw, force);
}

// ---- toggle con 3 dedos ----
@interface FFGesture : NSObject
@end

@implementation FFGesture
+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* w = UIApplication.sharedApplication.keyWindow;
        if (!w) return;
        UITapGestureRecognizer* t =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(tap)];
        t.numberOfTouchesRequired = 3;
        [w addGestureRecognizer:t];
    });
}
+ (void)tap {
    g_on = !g_on;
    UIImpactFeedbackGenerator* h =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [h impactOccurred];
    NSLog(@"[ffautoaim] %@", g_on ? @"ON" : @"OFF");
}
@end

__attribute__((constructor))
static void Init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4ull * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        Resolve();
        uintptr_t a = FindMethod("AimController", "SetAimRotation", 3);
        if (a) DobbyHook((void*)a, (void*)HookAim, (void**)&origAim);
        else   NSLog(@"[ffautoaim] offset de apuntado no encontrado");
        [FFGesture install];
    });
}
