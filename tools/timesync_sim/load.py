import re,datetime as dt,numpy as np
def load(n):
    T=[];D=[];R=[];E=[]
    for l in open(n+".log",errors="replace"):
        m=re.match(r"(\S+ \S+) \[Debug\] \(TimeSync\) (-?\d+)\t(-?\d+)\t(-?\d+)",l)
        if m:
            T.append(dt.datetime.strptime(m.group(1),"%Y-%m-%d %H-%M-%S.%f").timestamp()); D.append(int(m.group(2))); R.append(int(m.group(3))); E.append(int(m.group(4)))
    return np.array(T),np.array(D,float),np.array(R,float),np.array(E,float)
