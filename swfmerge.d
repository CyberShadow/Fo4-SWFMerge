import std.file;
import std.path;
import std.process;
import std.stdio;

import ae.sys.file;

immutable swixExeBytes = import("SwiXConsole.exe");

enum tempDir = "SWFMerge.temp";

struct Resource
{
	string name;
	immutable(ubyte)[] data;
}

immutable Resource[] resources =
[
	Resource("main.exe"       , cast(immutable(ubyte)[])import("main.exe"       )),
	Resource("SwiXConsole.exe", cast(immutable(ubyte)[])import("SwiXConsole.exe")),
	Resource("git2.dll"       , cast(immutable(ubyte)[])import("git2.dll"       )),
];

int main(string[] args)
{
	chdir(args[0].dirName.absolutePath);

	stdout.write("Unpacking...\r"); stdout.flush();

	tempDir.recreateEmptyDirectory();
	debug {} else scope(exit) tempDir.forceDelete(Yes.recursive);

	foreach (resource; resources)
		std.file.write(tempDir.buildPath(resource.name), resource.data);

	return spawnProcess([tempDir.buildPath("main.exe")] ~ args[1..$]).wait();
}
