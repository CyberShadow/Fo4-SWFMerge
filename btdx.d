import std.algorithm.searching;
import std.exception;
import std.stdio;
import std.string;

struct BTDX
{
	this(string filename)
	{
		f = File(filename, "rb");
		enforce(read!(char[4]) == "BTDX", "Wrong header");
		enforce(read!uint == 1, "Unknown version");
		//enforce(read!(char[4]) == "GNRL", "Wrong header 2");
		read!(char[4]);
		auto entryCount = read!uint();
		auto indexOffset = read!uint();
		read!uint();
		entries = read!Entry(entryCount);

		f.seek(indexOffset);
		foreach (n; 0..entryCount)
			names ~= read!char(read!ushort()).assumeUnique();
	}

	void[] extract(string name)
	{
		auto index = names.countUntil!(n => !n.icmp(name));
		enforce(index > 0, "No such file in archive");
		auto entry = &entries[index];
		f.seek(entry.offset);
		return read!void(entry.size);
	}

private:
	File f;

	struct Entry
	{
		uint unk1;
		char[4] type;
		uint unk2;
		uint unk3;
		uint offset;
		uint unk5;
		uint unk6;
		uint size;
		uint baadf00d;
	}
	Entry[] entries;
	string[] names;

	T read(T)()
	{
		T result;
		readExact(((&result)[0..1]));
		return result;
	}

	T[] read(T)(size_t size)
	{
		T[] result = new T[size];
		readExact(result);
		return result;
	}

	void readExact(void[] buffer)
	{
		enforce(f.rawRead(buffer).length == buffer.length, "Incomplete read");
	}
}
