# tools/diagnostics/macos_owned_private_session_test.py

"""Receive the exact production private-session primitive through real POSIX spawn."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
SOURCE = (
    ROOT
    / "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/OwnedProgramCompatibility.c"
)


def actual_function():
    text = SOURCE.read_text()
    at = text.index("int ergopti_owned_program_create_private_session(void)")
    end = text.index("\n}\n", at) + 3
    return text[at:end]


PREFIX = """
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
"""

DRIVER = """
int main(int argc, char **argv) {
 if(argc==2) {
  int original = getpgid(0)==getpid();
  if(strcmp(argv[1],"already-session")==0) {
   if(setsid()!=getpid()) return 10;
   return ergopti_owned_program_create_private_session()==EPERM ? 0 : 11;
  }
  int result=ergopti_owned_program_create_private_session();
  if(result!=0) return 12;
  if(getpgid(0)!=getpid() || getsid(0)!=getpid()) return 13;
  return strcmp(argv[1],"group")==0 ? (original ? 0 : 14) : (original ? 15 : 0);
 }
 posix_spawnattr_t attributes;
 if(posix_spawnattr_init(&attributes)!=0) return 16;
 short flags=strcmp(argv[1],"group")==0 ? POSIX_SPAWN_SETPGROUP : 0;
 if(posix_spawnattr_setflags(&attributes,flags)!=0 || posix_spawnattr_setpgroup(&attributes,0)!=0) return 17;
 pid_t child; char *arguments[]={argv[0],argv[1],NULL};
 int result=posix_spawn(&child,argv[0],NULL,&attributes,arguments,environ);
 posix_spawnattr_destroy(&attributes); if(result!=0) return 18;
 int status; if(waitpid(child,&status,0)!=child) return 19;
 return WIFEXITED(status) ? WEXITSTATUS(status) : 20;
}
""".replace("if(argc==2)", 'if(argc==2 && getenv("ERGOPTI_PRIVATE_SESSION_CHILD")!=NULL)').replace(
    "int result=posix_spawn(&child",
    'if(setenv("ERGOPTI_PRIVATE_SESSION_CHILD","1",1)!=0) return 21;\n int result=posix_spawn(&child',
)
PREFIX += "#include <stdlib.h>\n"


MOCK_PORTS = r"""
static int mode, session_calls, group_calls, parent_calls, parent_group_calls;
static pid_t fake_pid(void) { return 100; }
static pid_t fake_parent(void) { parent_calls++; return mode==4 && parent_calls>1 ? 201 : (mode==3 ? 1 : 200); }
static pid_t fake_group(pid_t p) {
 if(p==0) return session_calls>=2 ? (mode==7 ? 101 : 100) : (mode==2 ? 99 : 100);
 parent_group_calls++; return mode==5 && parent_group_calls>1 ? 301 : 300;
}
static pid_t fake_session(pid_t p) {
 if(p==0) return session_calls>=2 ? (mode==8 ? 101 : 100) : (mode==1 ? 100 : 10);
 return mode==6 ? 11 : 10;
}
static pid_t fake_setsid(void) { session_calls++; if(session_calls==1) { errno=mode==0 ? EACCES : EPERM; return -1; } return 100; }
static int fake_setpgid(pid_t p,pid_t g) { group_calls++; if(p!=0 || g!=300) return -1; if(mode==9) { errno=EACCES; return -1; } return 0; }
#define getpid fake_pid
#define getppid fake_parent
#define getpgid fake_group
#define getsid fake_session
#define setsid fake_setsid
#define setpgid fake_setpgid
"""
MOCK_DRIVER = r"""
int main(void) {
 const int expected[]={EACCES,EPERM,EPERM,ESTALE,ESTALE,ESTALE,ESTALE,EPROTO,EPROTO,EACCES};
 for(mode=0;mode<10;mode++) {
  session_calls=group_calls=parent_calls=parent_group_calls=0;
  if(ergopti_owned_program_create_private_session()!=expected[mode]) return 30+mode;
  if(mode<7 && group_calls!=0) return 50+mode;
 }
 return 0;
}
"""


class PrivateSessionReceiving(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="ergopti-private-session-")
        cls.binary = Path(cls.temporary.name) / "private-session"
        code = Path(cls.temporary.name) / "primitive.c"
        code.write_text(PREFIX + actual_function() + DRIVER)
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(code), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def receive(self, mode):
        child_environment = dict(os.environ)
        child_environment.pop("ERGOPTI_PRIVATE_SESSION_CHILD", None)
        result = subprocess.run(
            [str(self.binary), mode], env=child_environment, timeout=5, check=False
        )
        self.assertEqual(result.returncode, 0)

    def test_original_group_leader_guard_fails_the_same_real_posix_spawn(self):
        code = Path(self.temporary.name) / "original.c"
        binary = Path(self.temporary.name) / "original"
        code.write_text(
            PREFIX
            + "int ergopti_owned_program_create_private_session(void) { return setsid()==getpid() ? 0 : errno; }\n"
            + DRIVER
        )
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(code), "-o", str(binary)],
            check=True,
        )
        child_environment = dict(os.environ)
        child_environment.pop("ERGOPTI_PRIVATE_SESSION_CHILD", None)
        result = subprocess.run(
            [str(binary), "group"], env=child_environment, timeout=5, check=False
        )
        self.assertEqual(result.returncode, 12)

    def test_ten_independent_exact_parent_session_and_final_isolation_refusals(self):
        code = Path(self.temporary.name) / "refusals.c"
        binary = Path(self.temporary.name) / "refusals"
        code.write_text(PREFIX + MOCK_PORTS + actual_function() + MOCK_DRIVER)
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(code), "-o", str(binary)],
            check=True,
        )
        result = subprocess.run([str(binary)], timeout=5, check=False)
        self.assertEqual(result.returncode, 0)

    def test_real_foundation_equivalent_group_leader_becomes_own_session(self):
        self.receive("group")

    def test_real_inherited_group_becomes_own_session_without_rejoining(self):
        self.receive("inherited")

    def test_already_session_leader_remains_refused_without_parent_group_rejoin(self):
        self.receive("already-session")


if __name__ == "__main__":
    unittest.main(verbosity=2)
