import sys, numpy as np
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from l05_mzi_mesh import decompose, reconstruct, svd_program, energy_per_mac

rng = np.random.default_rng(7)
print("=== Clements decomposition: does the mesh rebuild the target unitary? ===")
ok = True
for n in (2, 3, 4, 6, 8):
    # Haar-random unitary
    z = (rng.normal(size=(n, n)) + 1j*rng.normal(size=(n, n))) / np.sqrt(2)
    q, r = np.linalg.qr(z)
    u = q @ np.diag(np.diag(r)/np.abs(np.diag(r)))
    prog = decompose(u)
    back = reconstruct(prog)
    err = np.max(np.abs(back - u))
    good = err < 1e-9
    ok = ok and good
    print("  n=%d  mzis=%2d (ideal %2d)  max_err=%.3e  %s"
          % (n, prog.mzi_count, prog.ideal_mzi_count, err, "OK" if good else "MISMATCH"))
print()
print("=== W = U.Sigma.V* factorisation ===")
w = rng.normal(size=(4,4))
pu, s, pv = svd_program(w)
recon = reconstruct(pu) @ np.diag(s) @ reconstruct(pv)
print("  max |W - U.S.V*| = %.3e" % np.max(np.abs(recon - w)))
print("  singular values  :", np.round(s, 4))
print("  NOTE max(sigma)=%.3f > 1 -> attenuators cannot amplify; needs normalisation" % s.max())
print()
print("=== energy floor (optical + phase hold only) ===")
for n in (8, 16, 64):
    print("  n=%2d  %.4f pJ/MAC" % (n, energy_per_mac(n)))
print("  spec claims <= 0.1 pJ/MAC")
sys.exit(0 if ok else 1)
