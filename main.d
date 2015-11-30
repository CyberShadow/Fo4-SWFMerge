import core.sys.windows.winuser;

import std.algorithm.iteration;
import std.array;
import std.base64;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;
import std.utf;

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
import ae.utils.text;

import abcfile;
import asprogram;
import assembler;
import disassembler;

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

enum tempDir = "SWFMerge.temp";

void swix(string[] args)
{
	auto swixExe = tempDir.buildPath("SwiXConsole.exe");
	enforce(spawnProcess([swixExe] ~ args, stdin, stdout, stderr, ["COMSPEC":"?*<>"], Config.none).wait() == 0, "SwiX failed");
}

void unpackSWF(string swf, string dir)
{
	stderr.writeln(">> Unpacking ", swf);
	dir.recreateEmptyDirectory();
	auto xml = dir.buildPath("swix.xml");
	swix(["swf2xml", swf, xml]);
	enforce(xml.exists, "SwiX unpack failed");

	auto lines = xml.readText().splitAsciiLines();
	size_t tagEnd = 0;
	int index = 0;
	foreach_reverse (i, line; lines)
	{
		line = line.strip();
		if (line == "</DoABCData>")
			tagEnd = i;
		else
		if (line == "<DoABCData>")
		{
			enforce(tagEnd, "Incomplete SwiX file");
			enforce(lines[i+1].strip() == "<![CDATA[" && lines[tagEnd-1].strip() == "]]>", "No CDATA wrapper");
			auto b64data = lines[i+2..tagEnd-1].map!strip().join();
			auto abcDir = "abc%d".format(index++);
			lines = lines[0..i+1] ~ [`<ExternABC Dir="` ~ abcDir ~ `"/>`] ~ lines[tagEnd..$];
			tagEnd = 0;

			stderr.writeln(">>> Disassembling ", abcDir);
			auto abcData = Base64.decode(b64data);
			scope abc = ABCFile.read(abcData);
			scope as = ASProgram.fromABC(abc);
			scope disassembler = new Disassembler(as, buildPath(dir, abcDir), abcDir);
			disassembler.dumpRaw = false;
			disassembler.disassemble();
		}
	}
	std.file.write(xml, lines.join("\r\n"));
}

void packSWF(string dir, string swf)
{
	stderr.writeln(">> Packing ", dir);
	auto xml = dir.buildPath("swix.xml");

	auto lines = xml.readText().splitAsciiLines();
	size_t tagEnd = 0;
	int index = 0;
	foreach_reverse (i, line; lines)
	{
		if (line.startsWith(`<ExternABC Dir="`))
		{
			auto abcDir = line[16..$-3];
			auto mainFile = buildPath(dir, abcDir, abcDir ~ ".main.asasm");

			stderr.writeln(">>> Assembling ", abcDir);
			auto as = new ASProgram;
			auto assembler = new Assembler(as);
			assembler.assemble(mainFile);
			auto abc = as.toABC();
			auto abcData = abc.write();
			auto b64Data = Base64.encode(abcData).assumeUnique();

			lines = lines[0..i] ~ ["<![CDATA[", b64Data , "]]>"] ~ lines[i+1..$];
		}
	}
	std.file.write(xml, lines.join("\r\n"));

	swix(["xml2swf", xml, swf]);
	enforce(swf.exists, "SwiX pack failed");
}

void mergeSWF(string base, string a, string b, string result)
{
	auto repoPath = tempDir.buildPath("Repo");
	repoPath.recreateEmptyDirectory();
	auto repo = initRepository(repoPath, OpenBare.no);

	GitTree addSWF(string swf, string name)
	{
		auto dataPath = tempDir.buildPath("Repo-Data-" ~ name);
		unpackSWF(swf, dataPath);
		return repo.addDir(dataPath);
	}

	auto baseTree = addSWF(base, "Base");
	auto branch1  = addSWF(a, "BranchA");
	auto branch2  = addSWF(b, "BranchB");

	stderr.writeln(">> Merging");

	auto index = repo.mergeTrees(baseTree, branch1, branch2);
	if (index.hasConflicts())
	{
		foreach (ancestor, our, their; &index.conflictIterator)
			throw new Exception("Conflict in " ~ ancestor.path);
		assert(false, "Can't find conflict");
	}

	auto workPath = tempDir.buildPath("Repo-Work");
	workPath.recreateEmptyDirectory();
	repo.setWorkPath(workPath);

	auto oid = index.writeTree(repo);
	GitCheckoutOptions opts = { strategy : GitCheckoutStrategy.force };
	repo.checkout(repo.lookupTree(oid), opts);

	packSWF(workPath, result);
}

void run(string[] args)
{
	writeln("SWF Merge for Fallout 4 v0.2 by CyberShadow");
	writeln("https://github.com/CyberShadow/Fo4-SWFMerge");
	writeln();

	enforce("Fallout4.exe".exists && "Data".exists,
		"Please place this program in your Fallout 4 game directory\n" ~
		`(e.g. "C:\Program Files (x86)\Steam\steamapps\common\Fallout 4").`);
	enforce(args.length == 2 && args[1].baseName().toLower().isOneOf("data", "interface"),
		`Please drag-and-drop a mod's "Data" or "Interface" directory on this program.`);

	auto inputDataDir = args[1];
	enforce(inputDataDir.exists, "Directory does not exist: " ~ inputDataDir);

	if (inputDataDir.baseName().toLower() == "interface")
	{
		auto inputDataDir2 = tempDir.buildPath("InputData");
		mkdirRecurse(inputDataDir2);
		dirLink(inputDataDir, inputDataDir2.buildPath("Interface"));
		inputDataDir = inputDataDir2;
	}

	auto archive = BTDX(`Data\Fallout4 - Interface.ba2`);

	auto outDir = tempDir.buildPath("Out");
	mkdirRecurse(outDir);

	stderr.writeln("=== Preparing ===");

	foreach (de; inputDataDir.dirEntries(SpanMode.breadth))
	{
		auto inputPath = de.name;
		auto relPath = inputPath.absolutePath().relativePath(inputDataDir.absolutePath());
		auto gamePath = buildPath("Data", relPath);
		auto outPath = buildPath(outDir, relPath);

		if (de.isDir)
		{
			stderr.writeln("> Entering ", relPath);
			mkdir(outPath);
		}
		else
		if (!gamePath.exists)
		{
			stderr.writeln("> Copying ", relPath);
			copy(inputPath, outPath);
		}
		else
		if (std.file.read(inputPath) == std.file.read(gamePath))
		{
			stderr.writeln("> Already installed: ", relPath);
		}
		else
		{
			stderr.writeln("> Merging ", relPath);
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

	stderr.writeln("Ready.");

	if (messageBox("This mod is compatible and can be installed.\nProceed with installation?", "SWFMerge", MB_YESNO | MB_ICONQUESTION) != IDYES)
	{
		stderr.writeln("User abort.");
		return;
	}

	stderr.writeln("=== Installing ===");

	foreach (de; outDir.dirEntries(SpanMode.breadth))
	{
		auto outPath = de.name;
		auto relPath = outPath.absolutePath().relativePath(outDir.absolutePath());
		auto gamePath = buildPath("Data", relPath);

		if (de.isDir)
		{
			if (!gamePath.exists)
			{
				stderr.writeln("> Creating ", relPath);
				mkdir(gamePath);
			}
		}
		else
		if (!gamePath.exists)
		{
			stderr.writeln("> Copying ", relPath);
			debug{} else copy(outPath, gamePath);
		}
	}

	stderr.writeln("All done!");
	debug {} else messageBox("All done!", "SWFMerge", MB_ICONINFORMATION);
}

int main(string[] args)
{
	try
	{
		run(args);
		return 0;
	}
	catch (Throwable e)
	{
		stderr.writeln(e);
		debug {} else messageBox(e.msg, "SWFMerge - Fatal " ~ e.classinfo.name.split(".")[$-1], MB_ICONERROR);
		return 1;
	}
}
