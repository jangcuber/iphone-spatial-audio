from load import *
import sys
def run(T,D,R,est_fn):
    out=[]; buf=[]; last=None
    for t,d,r in zip(T,D,R):
        if last is not None and t-last>60: buf=[]
        last=t; buf.append((t,d,r)); buf=buf[-200:]
        out.append(est_fn(np.array(buf),t))
    return np.array(out)
def A(b,t): return np.median(b[:,1])
def lowq(frac,minn,slope_span=60,window=None):
    def f(b,t):
        if window: b=b[b[:,0]>t-window]
        idx=np.argsort(b[:,2]); k=max(min(len(b),minn),int(len(b)*frac)); s=b[idx[:k]]
        sl=0
        if s[:,0].max()-s[:,0].min()>slope_span and len(s)>=10:
            sl=np.polyfit(s[:,0]-t,s[:,1],1)[0]
            if abs(sl)>1e-4: sl=0
        return np.median(s[:,1]-sl*(s[:,0]-t))*1+0
    return f
def lowabs(margin_us,minn=5,slope_span=60):
    def f(b,t):
        m=b[:,2].min(); s=b[b[:,2]<=m+margin_us]
        if len(s)<minn: s=b[np.argsort(b[:,2])[:minn]]
        sl=0
        if s[:,0].max()-s[:,0].min()>slope_span and len(s)>=10:
            sl=np.polyfit(s[:,0]-t,s[:,1],1)[0]
            if abs(sl)>1e-4: sl=0
        return np.median(s[:,1]-sl*(s[:,0]-t))
    return f
cands={"A median(all)":A,"low25%+line":lowq(.25,10),"low10%+line":lowq(.10,5),"low25% no-line":lowq(.25,10,slope_span=1e9),
       "low25% last60s":lowq(.25,5,slope_span=1e9,window=60),"minRTT+1.5ms +line":lowabs(1500),"minRTT+3ms +line":lowabs(3000)}
for n in ["node-01","node-02","node-03","node-04","node-05"]:
    T,D,R,E=load(n); t0=T[0]
    lo=R<=np.percentile(R,10); k=np.polyfit(T[lo]-t0,D[lo],1); truth=np.polyval(k,T-t0)
    print("==",n)
    for name,f in cands.items():
        e=(run(T,D,R,f)-truth)/1000
        # 150s change: max over sessions of |e(t)-e(t-150)|
        ch=[abs(e[i]-e[j]) for i in range(len(T)) for j in [np.searchsorted(T,T[i]-150)] if T[i]-T[j]>140 and T[i]-T[j]<160]
        print(f"  {name:22s} err p5/50/95 {np.percentile(e,5):+.2f}/{np.median(e):+.2f}/{np.percentile(e,95):+.2f}  150s-change p95 {np.percentile(ch,95):.2f} max {max(ch):.2f}")
