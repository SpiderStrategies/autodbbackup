#   Copyright 2012 Spider Strategies, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
use Config::Properties;
use File::Copy;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Amazon::S3;

# load the properties file
open PROPS, "< config.properties"
  or die "unable to open configuration file";
my $properties = new Config::Properties();
$properties->load(*PROPS);

# set some internal constants
$backupDirectoryName = "backups";

# read in the properties from the configuration file
$dbusername = $properties->getProperty('dbusername');
$dbpassword = $properties->getProperty('dbpassword');
$s3KeyPrefix = $properties->getProperty('s3keyprefix');
$s3id = $properties->getProperty('s3id');
$s3password = $properties->getProperty('s3password');
$s3bucket = $properties->getProperty('s3bucket');
$parentOutputLocation = $properties->getProperty('outputlocation');
$outputlocation = "$parentOutputLocation/$backupDirectoryName"; 

# TODO: Ideally we'd get the list of everything from the db if this was null (project for another day)
# create a list of databased
@databases = split(/\,/, $properties->getProperty('databases'));



# figure out the day of the week
@dotwAbbr = qw( Sunday Monday Tuesday Wednesday Thursday Friday Saturday );
$dayOfTheWeek = @dotwAbbr[(localtime(time()))[6]];

# keeps track of all the database backup filenames we've created
my @databaseFileNames = ();

# create our working directory
mkdir($outputlocation);

# iterate over each database listed in file
foreach $database (@databases) 
{
	print "processing: $database \n";
	
	# figure out where to write the file
	$dbFileName = $database . ".sql";
	push @databaseFileNames, $dbFileName;
	
	$dbFileLocation = $outputlocation . "/" . $dbFileName;
	
	# open the location and write the drop db string
	open(DBBACKUP, "> $dbFileLocation");
	print DBBACKUP "drop database if exists $database;\n";
	close(DBBACKUP);
	
	# create the backup command
	$command = "mysqldump -u $dbusername -p$dbpassword --databases " . $database . " >> $dbFileLocation";
	
	# run the command
	$result = `$command`;
	
	# print any errors
	print $result, "\n";
}


# create batch files to restore all of the databases;
open(RESTORE_BAT, "> $outputlocation/restore.bat");
open(RESTORE_SH, "> $outputlocation/restore.sh");

# add to the restore file
$alldbs = join(' ', @databaseFileNames);
print RESTORE_BAT "type $alldbs | mysql -u root -p\n";
print RESTORE_SH "cat $alldbs | mysql -u root -p\n";

# close the restore files
close(RESTORE_BAT);
close(RESTORE_SH);




# zip up the directory

# create the zip file object
$zipoutput = $outputlocation . ".zip";
$dayofweekzipoutput = $outputlocation . "_" . $dayOfTheWeek . ".zip";
$zip = Archive::Zip->new();

# add the restore scripts
$zip->addFile( "$outputlocation/restore.bat", "restore.bat" );
$zip->addFile( "$outputlocation/restore.sh", "restore.sh" );

# add the database backup sql files
foreach $databaseFileName (@databaseFileNames) {
	$zip->addFile( "$outputlocation/$databaseFileName", $databaseFileName );
}

# write the archive
unless ( $zip->writeToFileNamed($zipoutput) == AZ_OK ) {
	die 'write error';
}

# copy the zip file to a day of the week
# what we're doing here is copying this backup to a file with the name of a day of the week.
copy($zipoutput, $dayofweekzipoutput);

$s3 = Amazon::S3->new(
	{
		aws_access_key_id     => $s3id,
		aws_secret_access_key => $s3password
	}
);

$bucket = $s3->bucket($s3bucket);

print "uploading to:", $bucket->{bucket}, "\n";

# Adding the current copy of the databases
$bucket->add_key_filename(
	$s3KeyPrefix . $backupDirectoryName . ".zip", $zipoutput,
	{   
		content_type        => 'application/zip'
	}
);

# TODO: Change this so it uses an on-server key copy instead of sending the file again
# Adding the backup copy
$bucket->add_key_filename(
	$s3KeyPrefix . $backupDirectoryName . "_" . $dayOfTheWeek . ".zip", $zipoutput,
	{   
		content_type        => 'application/zip'
	}
);


print "Done!\n";
