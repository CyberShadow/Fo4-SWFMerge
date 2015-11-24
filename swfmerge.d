import core.sys.windows.winuser;

import std.array;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

import git.blob;
import git.checkout;
import git.commit;
import git.index;
import git.merge;
import git.oid;
import git.repository;
import git.signature;
import git.tree;
import git.types;

import ae.sys.file;
import ae.sys.windows.misc;
import ae.utils.array;

import btdx;

pragma(lib, "git2");

GitTree addDir(ref GitRepo repo, string path)
{
	auto tb = createTreeBuilder();
	foreach (de; dirEntries(path, SpanMode.shallow))
	{
		GitOid oid = de.isDir ? repo.addDir(de.name).id : repo.createBlob(cast(ubyte[])de.name.read());
		tb.insert(de.baseName, oid, de.isDir ? GitFileModeType.tree : GitFileModeType.blob);
	}		
	return repo.lookupTree(tb.write(repo));
}

immutable swixExeBytes = cast(immutable(ubyte)[])import("SwiXConsole.exe");

enum tempDir = "SWFMerge.temp";

void swix(string[] args)
{
	auto swixExe = tempDir.buildPath("SwiXConsole.exe");
	if (!swixExe.exists)
		std.file.write(swixExe, swixExeBytes);
	enforce(spawnProcess([swixExe] ~ args, stdin, stdout, stderr, ["COMSPEC":"?*<>"], Config.none).wait() == 0, "SwiX failed");
}

void unpackSWF(string swf, string dir)
{
	dir.recreateEmptyDirectory();
	auto xml = dir.buildPath("swix.xml");
	swix(["swf2xml", swf, xml]);
	enforce(xml.exists, "SwiX unpack failed");
}

void packSWF(string dir, string swf)
{
	dir.recreateEmptyDirectory();
	auto xml = dir.buildPath("swix.xml");
	swix(["xml2swf", xml, swf]);
	enforce(xml.exists, "SwiX pack failed");
}

void mergeSWF(string base, string a, string b, string result)
{
	auto repoPath = tempDir.buildPath("Repo");
	repoPath.recreateEmptyDirectory();
	auto repo = initRepository(repoPath, OpenBare.no);

	GitTree addSWF(string swf)
	{
		auto dataPath = tempDir.buildPath("Repo-Data");
		unpackSWF(swf, dataPath);
		return repo.addDir(dataPath);
	}

	auto baseTree = addSWF(base);
	auto branch1  = addSWF(a);
	auto branch2  = addSWF(b);

	enum workPath = tempDir.buildPath("Repo-Work");
	workPath.recreateEmptyDirectory();
	repo.setWorkPath(workPath);

	auto index = repo.mergeTrees(baseTree, branch1, branch2);
	if (index.hasConflicts())
	{
		foreach (ancestor, our, their; &index.conflictIterator)
			throw new Exception("Conflict in " ~ ancestor.path);
		assert(false, "Can't find conflict");
	}

	auto oid = index.writeTree(repo);
	GitCheckoutOptions opts = { strategy : GitCheckoutStrategy.force };
	repo.checkout(repo.lookupTree(oid), opts);

	packSWF(workPath, result);
}

void run(string[] args)
{
	writeln("SWF Merge for Fallout 4 v0.1 by CyberShadow");
	writeln("https://github.com/CyberShadow/Fo4-SWFMerge");
	writeln();

	enforce("Fallout4.exe".exists && "Data".exists,
		"Please place this program in your Fallout 4 game directory\n" ~
		`(e.g. "C:\Program Files (x86)\Steam\steamapps\common\Fallout 4").`);
	enforce(args.length == 2 && args[1].baseName().toLower().isOneOf("data", "interface"),
		`Please drag-and-drop a mod's "Data" or "Interface" directory on this program.`);

	tempDir.recreateEmptyDirectory();
	debug {} else scope(exit) tempDir.forceDelete(Yes.recursive);

	auto inputDataDir = args[1];
	enforce(inputDataDir.exists, "Directory does not exist: " ~ inputDataDir);

	if (inputDataDir.baseName().toLower() == "interface")
	{
		auto inputDataDir2 = tempDir.buildPath("InputData");
		mkdir(inputDataDir);
		dirLink(inputDataDir, inputDataDir2.buildPath("Interface"));
		inputDataDir = inputDataDir2;
	}

	auto archive = BTDX(`Data\Fallout4 - Interface.ba2`);

	auto outDir = tempDir.buildPath("Out");
	mkdir(outDir);

	stderr.writeln("=== Preparing ===");

	foreach (de; inputDataDir.dirEntries(SpanMode.breadth))
	{
		auto inputPath = de.name;
		auto relPath = inputPath.relativePath(inputDataDir);
		auto gamePath = buildPath("Data", relPath);
		auto outPath = buildPath(outDir, relPath);

		if (de.isDir)
		{
			stderr.writeln("Entering ", relPath);
			mkdir(outPath);
		}
		else
		if (!gamePath.exists)
		{
			stderr.writeln("Copying ", relPath);
			copy(inputPath, outPath);
		}
		else
		if (std.file.read(inputPath) == std.file.read(gamePath))
		{
			stderr.writeln("Already installed: ", relPath);
		}
		else
		{
			stderr.writeln("Merging ", relPath);
			enforce(relPath.toLower.startsWith(`interface\`), "Non-Interface file conflict: " ~ relPath);
			enforce(relPath.toLower.endsWith(".swf"), "Non-SWF file conflict: " ~ relPath);

			auto baseSWF = tempDir.buildPath("base.swf");
			std.file.write(baseSWF, archive.extract(relPath));

			try
				mergeSWF(baseSWF, inputPath, gamePath, outPath);
			catch (Exception e)
			{
				e.msg = "Error with " ~ relPath ~ ": " ~ e.msg;
				throw e;
			}
		}
	}

	stderr.writeln("=== Installing ===");
	debug { writeln("Press Enter to continue"); readln(); }

	foreach (de; outDir.dirEntries(SpanMode.breadth))
	{
		auto outPath = de.name;
		auto relPath = outPath.relativePath(inputDataDir);
		auto gamePath = buildPath("Data", relPath);

		if (de.isDir)
		{
			if (!gamePath.exists)
			{
				stderr.writeln("Creating ", relPath);
				mkdir(gamePath);
			}
		}
		else
		if (gamePath.exists)
		{
			stderr.writeln("Copying ", relPath);
			copy(outPath, gamePath);
		}
	}

	stderr.writeln("All done!");
}

int main(string[] args)
{
	try
	{
		run(args);
		debug {} else messageBox("All done!", "SWFMerge", MB_ICONINFORMATION);
		return 0;
	}
	catch (Throwable e)
	{
		stderr.writeln(e);
		debug {} else messageBox(e.msg, "SWFMerge - Fatal " ~ e.classinfo.name.split(".")[$-1], MB_ICONERROR);
		return 1;
	}
}
