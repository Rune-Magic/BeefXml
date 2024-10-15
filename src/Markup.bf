using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections;

namespace Xml;

enum MarkupUri
{
	case Public(String publicId, String uri);
	case System(String uri);
	case Raw(String raw);

	public static Result<Self> Parse(MarkupSource source, BumpAllocator alloc, bool allowRaw = false)
	{
		Result<String> NextQuotedString()
		{
			String builder = new:alloc .(16);
			char32 c;
			char8 quote = 0;
			if (source.Consume('"')) quote = '"';
			else if (source.Consume('\'')) quote = '\'';
			else
			{
				source.Error("Expected quoted string");
				return .Err;
			}
			while (true)
			{
				if (!source.PeekNext(out c, let length))
				{
					source.Error("String was not closed");
					return .Err;
				}
				source.MoveBy(length);
				if (c == quote) break;
				builder.Append(c);
			}
			return builder;
		}

		if (source.Consume("SYSTEM"))
			return .Ok(.System(Try!(NextQuotedString())));
		if (source.Consume("PUBLIC"))
			return .Ok(.Public(Try!(NextQuotedString()), Try!(NextQuotedString())));
		if (allowRaw)
			return .Ok(.Raw(Try!(NextQuotedString())));

		source.Error("Expected SYSTEM or PUBLIC");
		return .Err;
	}

	public Result<Stream> Open(MarkupSource source)
	{
		switch (this)
		{
		case .Raw(let raw):
			Internal.FatalError("cannot open raw data");
		case .Public(?, var uri), .System(out uri):
			return source.OpenUri(uri);
		}
	}

	public String Name
	{
		get
		{
			switch (this)
			{
			case .Raw: return "<inline>";
			case .Public(?, let uri): return uri;
			case .System(let uri): return uri;
			}
		}
	}

	public override void ToString(String strBuffer)
	{
		mixin Escape(String str)
		{
			String copy = scope:mixin .(str.Length);
			for (let char in str.DecodedChars)
			{
				switch (Util.MatchBaseXmlEntity(char))
				{
				case .Ok(let val): copy.Append(val);
				case .Err: copy.Append(char);
				}
			}
			copy
		}

		switch (this)
		{
		case .Public(let publicId, let uri):
			strBuffer.AppendF($"PUBLIC \"{Escape!(publicId)}\" \"{Escape!(uri)}\">");
		case .System(let uri):
			strBuffer.AppendF($"SYSTEM \"{Escape!(uri)}\">");
		case .Raw(let raw):
			strBuffer.AppendF($"\"{Escape!(raw)}\"");
		}
	}
}

/// represents parse-able text source
class MarkupSource
{
	public struct Index : this(int line, int col, MarkupSource parent)
	{
		public override void ToString(String strBuffer)
		{
			if (line < 0)
			{
				strBuffer.Append("in ");
				strBuffer.Append(parent.Name);
				return;
			}
			strBuffer.AppendF($"at line {line+1}:{col+1} in {parent.Name}");
		}

		public static Self operator--(Self self) => .(self.line, self.col-1, self.parent);
	}

	public bool Ended => bufferSizeToEnd <= 0 && Stream.EndOfStream;

	public StringView Name { get; private set; }
	public ref Index CurrentIdx { get; private set; } = .(0, 0, this);
	public StreamReader Stream { get; private set; }

	/// Assigning this will grant the parsers access to the internet
	/// needs to validate and open a url
	/// if the url is invalid return a .Err, so that we can print an error message after trying to open the filepath
	public function Result<Stream>(StringView url) OpenUrl { protected get; set; } = null;
	public Result<Stream> OpenUri(StringView uri)
	{
		if (OpenUrl != null)
		{
			switch (OpenUrl(uri))
			{
			case .Ok(let val): return val;
			case .Err:
			}
		}
		String filePath = Path.GetAbsolutePath(uri, Name, ..scope .(24));
		FileStream stream = new .();
		switch (stream.Open(filePath, access: .Read, share: .Read))
		{
		case .Err(let err):
			switch (err)
			{
			case .SharingViolation:
				Error($"File {filePath} is used by another process");
			case .Unknown:
				Error($"Something went wrong while opening file {filePath}, consider assigning OpenUrl");
			case .NotFound:
				Error($"No such file {filePath}");
			case .NotFile:
				Error($"{filePath} is not a file");
			}
			return .Err;
		case .Ok(let val):
			return stream;
		}
	}

	public StreamWriter ErrorStream { protected get; set; } = Console.Error;
	/// will keep track of the current line and write it along with an error
	/// will provide better error messages at the cost of performance
	public bool WriteErrorLines { protected get; set; }
#if DEBUG || TEST
		= true;
#else
		= false;
#endif

	protected int bufferSize;
	private char8* bufferStartPtr ~ if (ownsBuffer) Internal.StdFree(_);
	private char8* bufferIdx;
	private int bufferSizeToEnd;

	[AllowAppend]
	public this(StreamReader stream, StringView name, int bufferSize = 128) : this(bufferSize)
	{
		Stream = stream;
		Name = name;
		this.bufferSize = bufferSize;
		EmptyBuffer();
	}

	[AllowAppend]
	private this(int size)
	{
		char8[] buffer = append .[size];
		bufferStartPtr = buffer.Ptr;
	}

	private String currentLine = WriteErrorLines ? new .(32) : null ~ delete _;
	private void WriteIndex(Index index, int length)
	{
		if (!WriteErrorLines)
		{
			ErrorStream.WriteLine($" {index}");
			return;
		}

		int offset = 0;
		while (true)
		{
			if (offset > bufferSizeToEnd)
			{
				if (Stream.EndOfStream) break;
				Realloc(bufferSize * 2);
			}
			if (bufferIdx[offset] == '\n') break;
			currentLine.Append(bufferIdx[offset]);
			offset++;
		}

		ErrorStream
			..Write($" {index}\n    ")
			..WriteLine(currentLine)
			..Write(scope String(' ', index.col + 4))
			..WriteLine(scope String('^', length));
		ErrorStream.Flush();
	}

	public void Error(StringView errMsg)
	{
		ErrorStream..Write("ERROR: ")..Write(errMsg);
		WriteIndex(CurrentIdx--, 1);
		Debug.Break();
	}
	public void Error(StringView errMsg, params Object[] formatArgs)
	{
		ErrorStream..Write("ERROR: ")..Write(errMsg, params formatArgs);
		WriteIndex(CurrentIdx--, 1);
		Debug.Break();
	}
	public void ErrorNoIndex(StringView errMsg)
	{
		ErrorStream..Write("ERROR: ")..WriteLine(errMsg);
		Debug.Break();
	}
	public void ErrorNoIndex(StringView errMsg, params Object[] formatArgs)
	{
		[Inline]ErrorNoIndexNoNewLine(errMsg, params formatArgs);
		ErrorStream.WriteLine();
		Debug.Break();
	}
	[NoShow(true)]
	internal void ErrorNoIndexNoNewLine(StringView errMsg, params Object[] formatArgs)
	{
		ErrorStream..Write("ERROR: ")..Write(errMsg, params formatArgs);
		ErrorStream.Flush();
	}

	public void EmptyBuffer()
	{
		bufferIdx = bufferStartPtr;
		if (LoadBuffer(bufferStartPtr, bufferSize) case .Err(let err))
			bufferSizeToEnd = err;
		else
			bufferSizeToEnd = bufferSize;
	}

	public void ResetBuffer()
	{
		Internal.MemMove(bufferStartPtr, bufferIdx, bufferSizeToEnd);
		if (LoadBuffer(bufferStartPtr + bufferSizeToEnd, bufferSize - bufferSizeToEnd) case .Err(let err))
			bufferSizeToEnd += err;
		else
			bufferSizeToEnd = bufferSize;
		bufferIdx = bufferStartPtr;
	}

	bool ownsBuffer = false;
	public void Realloc(int size)
	{
		if (size <= bufferSizeToEnd) return;
		if (size <= bufferSize)
		{
			ResetBuffer();
			return;
		}
		int added = size - bufferSize;
		char8* newBuffer = (.)Internal.StdMalloc(size);
		Internal.MemCpy(newBuffer, bufferStartPtr, bufferSize);
		bufferIdx = (bufferIdx - bufferStartPtr) + newBuffer;
		if (LoadBuffer(newBuffer + bufferSize, added) case .Err(let err))
			bufferSizeToEnd += err;
		else
			bufferSizeToEnd += added;
		bufferSize = size;
		if (ownsBuffer) Internal.StdFree(bufferStartPtr);
		bufferStartPtr = newBuffer;
		ownsBuffer = true;
	}

	public Result<void> MoveBy(int by)
	{
		if (bufferSizeToEnd <= 0 && Ended)
			return .Err;

		mixin IncrementIdx(int i)
		{
			if (bufferIdx[i] == '\n')
			{
				CurrentIdx.line++;
				CurrentIdx.col = 0;
				currentLine?.Clear();
				continue;
			}
			currentLine?.Append(bufferIdx[i]);
			CurrentIdx.col++;
		}

		master: do
		{
			sub: do
			{
				for (let i < by)
				{
					if (i >= bufferSizeToEnd) break sub;
					IncrementIdx!(i);
				}
				break master;
			}

			int remaining = by - bufferSizeToEnd;
			if (remaining <= 0) break master;
			Realloc(remaining);
			for (let i < remaining)
			{
				IncrementIdx!(i);
			}

			bufferIdx += remaining;
			bufferSizeToEnd -= remaining;
			return .Ok;
		}

		bufferIdx += by;
		bufferSizeToEnd -= by;
		return .Ok;
	}

	[NoDiscard]
	public Result<void, int> LoadBuffer(char8* idx, int size)
	{
		for (let i < size)
			switch (Stream.Read())
			{
			case .Err:
				return .Err(i);
			case .Ok(out idx[i]):
			}
		return .Ok;
	}

	private mixin ClearNextWhitespace()
	{
		if (bufferSizeToEnd <= 0) EmptyBuffer();
		if (bufferSizeToEnd <= 0) return false;
		while (bufferIdx[0].IsWhiteSpace)
			TrySilent!(MoveBy(1));
	}

	private static mixin ElseFalse(var result)
	{
		if (result case .Err)
			return false;
	}

	public bool Consume(char8 c)
	{
		ClearNextWhitespace!();
		if (bufferIdx[0] != c) return false;
		return MoveBy(1) case .Ok;
	}

	public bool ConsumeWhitespace()
	{
		if (bufferSizeToEnd <= 0) EmptyBuffer();
		if (!bufferIdx[0].IsWhiteSpace) return false;
		ClearNextWhitespace!();
		return true;
	}

	public bool Consume(StringView str)
	{
		ClearNextWhitespace!();
		if (str.Length > bufferSizeToEnd)
			Realloc(str.Length);

		if (StringView(bufferIdx, str.Length) == str)
		{
			ElseFalse!(MoveBy(str.Length));
			return true;
		}
		return false;
	}

	public bool Consume(params StringView[] parts)
	{
		int offset = 0;
		for (let str in parts)
		{
			if (bufferIdx + offset >= bufferStartPtr + bufferSize)
			{
				if (Stream.EndOfStream) return false;
				Realloc(bufferSize * 2);
			}

			while ((bufferIdx + offset)[0].IsWhiteSpace)
			{
				offset++;
				if (bufferIdx + offset >= bufferStartPtr + bufferSize)
				{
					if (Stream.EndOfStream) return false;
					Realloc(bufferSize + bufferSize / 2);
				}
			}

			if (offset + str.Length > bufferSizeToEnd)
			{
				if (Stream.EndOfStream) return false;
				Realloc(offset + str.Length);
			}

			if (StringView((bufferIdx + offset), str.Length) != str)
				return false;

			offset += str.Length;
		}

		MoveBy(offset);

		return true;
	}

	public bool PeekNext(out char32 c, out int length)
	{
		if (bufferSizeToEnd < 4)
		{
			if (bufferSizeToEnd <= 0 && Ended)
			{
				c = ?;
				length = 0;
				return false;
			}
			Realloc(4);
		}
		(c, length) = UTF8.Decode(bufferIdx, bufferSizeToEnd);
		return true;
	}
}
