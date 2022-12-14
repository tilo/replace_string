# Replace String

If you want to make consistent changes in a large set of local files, this may be a useful and time-tested tool.

**Command line tool to do Multiple search-replace or query-search-replace operations on multiple files.**

This Perl script has been used extensively in production environments, is very powerful...
**Please read the disclaimer at the end of this file.**

Requires Perl5 to be installed.

`replace_string` consistently changes/modifies any number of text files, either interactively or in batch mode, either with or without keeping backups, preserve modes/owner when run as root.

It enables you to do a dry-run in interactive mode to see how your regular expressions will work, before you process all files in batch mode.

## Features:

* do multiple search-replace or query-search-replace operations
* search-replace expressions can be given on the command line or read from a file
* processes multiple input files
* recursively descend into directory and do multiple search/replace operations on all files
* user defined perl expressions are applied to each line of each input file
* optionally run in paragraph mode (for multi-line search/replace)
* interactive mode
* batch mode
* optionally backup files and backup numbering
* preserve modes/owner when run as root
* ignore symbolic links, empty files, write protected files, sockets, named pipes, and directory names
* optionally replace lines only matching / not matching a given regular expression


## Examples

You can specify PERL serch/replace statements either on the command line or put them into a replace-file. Usually these statements look something like this:

        s/oldstring/newstring/gi
        
replace_string slurps in these statements at the beginning, and then applies each of them to each line of each input file.

### Interactive-Mode

The search/replace operations are read from a file "replacements". The list of files to be processed is read from a file "inputfiles". Please note that the user can say yes or no to each case where one of the replace statements would apply, and that you get's pretty verbose feedback on what was changed, including the line number, and the exact line after applying the (multiple) changes.. For each modified file, a backup of the original file is kept. Interactice mode, and making backup files can be switched off.


        > cat replacements
        s/text/test/gi
        s/it/this/gi

        > cat inputfiles
        inputfile1
        inputfile2

	> replace_string -S replacements -F inputfiles

        reading file with substitution rules "replacements"

           s/text/test/gi
           s/it/this/gi

        ########################################
        file 1: "inputfile1"
        ########################################

        line    1 : "This is a text, only a text.. "
                ==> "This is a test, only a test.. "

          (2 substitutions)   substitute?  (y/n/!/q) y
        answer = 'y'
          substituted!

        line    3 : "to text it."
                ==> "to test this."

          (2 substitutions)   substitute?  (y/n/!/q) y
        answer = 'y'
          substituted!

        file "inputfile1" was modified!


        ########################################
        file 2: "inputfile2"
        ########################################

        line    1 : "Another text file"
                ==> "Another test file"

          (1 substitutions)   substitute?  (y/n/!/q) y
        answer = 'y'
          substituted!

        file "inputfile2" was modified!

          processed 2 files

### Batch-Mode

The same search/replace operations, but this time in batch-mode, without user-interaction.. and specifying a single search/replace operation and all input files on the command line.


	> ./replace_string -nq -s s/text/test/gi -f inputfile inputfile2
	   s/text/test/gi

	file 1: "inputfile"
	file "inputfile" was modified!

	file 2: "inputfile2"
	file "inputfile2" was modified!

	  processed 2 files


### Recursive Descend into Directory

To recursively descend into a directory and do multiple search/replace-operations on all files found in there, do the following:

        > ls dir
        inputfile1
        inputfile2
       
        > replace_string -S replacements -f `find dir -type f`
	reading file with substitution rules "replacements"

	   s/text/test/gi
	   s/it/this/gi

	########################################
	file 1: "dir/inputfile2"
	########################################

	line    1 : "Another text file"
		==> "Another test file"

	  (1 substitutions)   substitute?  (y/n/!/q) y
	answer = 'y'
	  substituted!

	file "dir/inputfile2" was modified!


	########################################
	file 2: "dir/inputfile1"
	########################################

	line    1 : "This is a text, only a text.. "
		==> "This is a test, only a test.. "

	  (2 substitutions)   substitute?  (y/n/!/q) y
	answer = 'y'
	  substituted!

	line    3 : "to text it."
		==> "to test this."

	  (2 substitutions)   substitute?  (y/n/!/q) y
	answer = 'y'
	  substituted!

	file "dir/inputfile1" was modified!

	  processed 2 files

### Recursive Descend into multiple Directories

This can easily be done along the same lines, as the example above...
Just use replace_string -S replacements -f `find dir1 dir2 -type f` to descend into two directories dir1 and dir2.
 

## Disclaimer

Submit your files to version control before running `replace_string`, or make backups of your real data before you run `replace_string`.  
  
Try out your serach/replace operations on a small copy of your real data
do a dry-run in query-mode (on a copy of your data!) before you process your real data!

`replace_string` is a pretty powerful tool which gives you the freedom of applying any perl expressions to every line in a number of files... and along the way possibly destroying all your data if you are not careful.. so don't come to me wining, you have been warned.


## License

replace_string is freely available under the terms of the OpenSource "Artistic License" 
  
