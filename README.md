Install Instructions
====================

1. Download and install Perl.  On windows, I used strawberry perl from the url [http://strawberryperl.com/](http://strawberryperl.com/).

2. Add required archives.

		perl -MCPAN -e "install Config::Properties"
		perl -MCPAN -e "install Amazon::S3"

3. To your classpath, add (whatever this location is on your machine):

	C:\strawberry\perl\site\lib\auto\XML\LibXML

4. Configure the properties file, config.properties
	* Set the db user name and password
	* Set the s3 id, password, bucket name
	* Set the uploaded file prefix (s3keyprefix). This is essentially the "directory" the backup will be in.  This must end with a front slash (/).
	* Set the databases to back up as a comma separated list (no spaces)
	* Set the location to be used for the sql files (outputlocation). If this is a windows system, you must use double backslashes.
	  
5. Configure your machine to invoke the backupdbs.pl
	1. Right click on "My Computer", click "Manage".
	2. Click Task Scheduler
	3. Click Create Basic Task from the right-hand pane
	4. Set the name (perhaps Backup Database).  Click next.
	5. Choose your frequency.  Click next.
	6. Set the time.  Click next.
	7. Start a program should be selected.  Click next.
	8. Set the program to be (or whatever your perl executable is): C:\strawberry\perl\bin\perl.exe
	9. Set your arguments to be: backupdbs.pl
	10. Set your starting location to be the directory of that perl script, like: C:\Users\Dan Kolz\git\autodbbackup_repo\autodbbackup\scripts
	11. Click next.
	12. Click finish.
