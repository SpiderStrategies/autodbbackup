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
use List::MoreUtils qw(firstidx);
use Net::Amazon::S3;
use Net::SMTP_auth;


# setup config file location
$configFileLocation = "config.properties";

# keeps track of all the database backup filenames we've created
@databaseFileNames = ();
@emailMessages = ();
$fileUsage = "multiple";
$deleteBackupFiles = "no";

setupConfigFileLocation();

setupConfiguredValues();

backupDatabases();


if($fileUsage eq "one") {
	writeRestoreFiles();
	
	# zip up the directory
	createSingleZipFile();
	
	# copy the zip file to a day of the week
#	createDayOfWeekCopies();

	# send the file (backup.zip) to s3
	sendFilesToS3();
	if("yes" eq $deleteBackupFiles) {
		deletePendingFiles();
	}
}



sendEmails();

print "Done!\n";


sub setupConfigFileLocation {
# handle command line parameters
	if ( @ARGV > 0 ) {
		
		$parm1 = shift @ARGV;
		if($parm1 eq '--help') {
			print "This program takes commands in the form of: backupdbs.pl <config-file-location>";
			exit;
		}
		
		# check to see if the config file location exists
		-e $parm1 or die "The config file location $parm1 can not be found.";
		
		$configFileLocation = $parm1;
	}
}

sub setupConfiguredValues {
	# load the properties file
	open PROPS, "< $configFileLocation"
	  or die "unable to open configuration file: $configFileLocation";
	  
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
	$rollingBackups = $properties->getProperty('rollingbackups');
	
	$emailAddressesProperty = $properties->getProperty('emailAddresses');
	if($emailAddressesProperty) {
		@emailAddresses = split(/\,/, $emailAddressesProperty);
	}
	else {
		print "No email addresses.\n";
	}
	
	$emailServer = $properties->getProperty('emailServer');
	$emailServerUser = $properties->getProperty('emailServerUser');
	$emailServerPassword = $properties->getProperty('emailServerPassword');
	$emailFrom = $properties->getProperty('emailFrom');
	
	
	$outputlocation = "$parentOutputLocation/$backupDirectoryName";
	
	if(! (-e $parentOutputLocation)) {
		print "The output directory $parentOutputLocation did not exist.  Please create it and run again.";
		exit;
	} 
	
	# if the backup directory doesn't exist, create it
	mkdir($outputlocation) unless -e $outputlocation;
	
	$databaseProperty = $properties->getProperty('databases');
	
	# If a set of databases wasn't listed, we can assumem they'd like to get the whole set
	if(!$databaseProperty || $databaseProperty eq '') {
		$query = "mysql -u $dbusername -p" . "$dbpassword -e \"SHOW DATABASES\" information_schema";
		@databases = `$query`;
		shift @databases;
		pop @databases;
		foreach $database (@databases) {
			# remove any of the box formatting that mysql may have added
			$database =~ s/[|]\s(\w*?)\s*[|]/$1/;
			
			# remove the return char
			chomp $database;
		}

		# remove information_schema and mysql since we probably don't want those
		@toRemove = qw / information_schema mysql /;
		@databases = removeItemNames(\@databases, \@toRemove);
	}
	else {
		# create a list of databases
		@databases = split(/\,/, $databaseProperty);
	}
	
	# figure out the day of the week
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time());
	@dotwAbbr = qw( Sunday Monday Tuesday Wednesday Thursday Friday Saturday );
	$dayOfTheWeek = @dotwAbbr[$wday];
	$weekOfTheMonth = "week" . sprintf("%d", $mday / 7);
	@monthAbbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
	$monthOfTheYear = $monthAbbr[$mon];
	$yearValue = $year + 1900;
	
}

# removeItemNames(@theSourceList, @theItemsToRemove)
sub removeItemNames {
	my @focus = @{shift @_};
	my @toRemove = @{shift @_};
	
	foreach my $item (@toRemove) {
		my $index = firstidx { $_ eq $item } @focus;
		if($index >= 0) {
			splice @focus, $index, 1;
		}
	}
	
	return @focus;
}

sub backupDatabases {
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
		
		unless($fileUsage eq "one") {
			createAndSendZipFileForDatabase($database);
		}
	}
}

sub writeRestoreFiles {
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
}

sub createSingleZipFile {
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
	
	# add the zip file to the list of files to send
	push @filesToSend, $zipoutput;
	
	push @filesToDelete, $zipoutput;
	push @filesToDelete, "$outputlocation/$databaseFileName";
	push @filesToDelete, "$outputlocation/restore.bat";
	push @filesToDelete, "$outputlocation/restore.sh";
}

sub createMultipleZipFiles {
	
	foreach $database (@databases) {
		createAndSendZipFileForDatabase($database);
	}
}


sub createAndSendZipFileForDatabase {
	my ($database) = @_;
	# create the zip file object
	my $zipoutput = "$parentOutputLocation/$database" .  ".zip";
#		my $dayofweekzipoutput = "$parentOutputLocation/$database" . "_" . $dayOfTheWeek . ".zip";
	my $zip = Archive::Zip->new();
	
	# add the restore scripts
	my $databaseSQLFileLocation = "$outputlocation/$database.sql";
	$zip->addFile( $databaseSQLFileLocation, "$database.sql" );
	
	# write the archive
	unless ( $zip->writeToFileNamed($zipoutput) == AZ_OK ) {
		print "Could not write zip file $zipoutput";
	}
	
	# what we're doing here is copying this backup to a file with the name of a day of the week.
#		copy($zipoutput, $dayofweekzipoutput);
	
	# add the zip file to the list of files to send
	push @filesToSend, $zipoutput;
	
	push @filesToDelete, $zipoutput;
	push @filesToDelete, $databaseSQLFileLocation;
	
	sendFilesToS3();
	
	if("yes" eq $deleteBackupFiles) {
		deletePendingFiles();
	}
}

sub deletePendingFiles {
	foreach my $fileToDelete (@filesToDelete) {
		deleteAFile($fileToDelete);
	}
	
	@filesToDelete = ();
}

sub deleteAFile {
	my ($fileName) = @_;
	my $retCode = unlink($fileName);
	print "ulinking file returned: $retCode \n"; 
	unless($retCode == 1) {
		my $msg = "The file $fileName was not deleted.\n";
		print $msg;
		push @emailMessages, $msg;
	}
}

sub sendFilesToS3 {
	$s3 = Net::Amazon::S3->new(
		{
			aws_access_key_id     => $s3id,
			aws_secret_access_key => $s3password,
			retry 				  => 1
		}
	);
	
	$bucket = $s3->bucket($s3bucket);
	
	print "uploading to:", $bucket->{bucket}, "\n";
	
	
	foreach $fileToSend (@filesToSend) {
		# Adding the current copy of the databases
		
		# find the last part of the name
		$fileToSend =~ m:.*[/](.*?)$:;
		$suffix = $1;
		
		my $status = $bucket->add_key_filename(
			$s3KeyPrefix . $suffix, $fileToSend,
			{   
				content_type        => 'application/zip'
			}
		);
		
		my $msg;
		if($status) {
			$msg = "Upload file $suffix of " .  (-s $fileToSend) . " bytes.";
		}
		else {
			$msg = "Could not upload file $suffix.";
		}
		print "$msg\n";
		
		createRollingBackupS3Keys($s3KeyPrefix . $suffix);
		
		push @emailMessages, $msg;
	}
	
	@filesToSend = ();
}

sub createRollingBackupS3Keys {
	my ($currentFileName) = @_;
	$currentFileName =~ m:(.*)[.](.*?)$:;
	$pre = $1;
	$post = "." . $2;
	
	my $currentS3Key = "/$s3bucket/$currentFileName";
	
	if($rollingBackups =~ m/day/) {
		my $s3duplicateDestination = $pre . "_" . $dayOfTheWeek . $post;
		$bucket->copy_key($s3duplicateDestination, $currentS3Key);
	}
	if($rollingBackups =~ m/week/) {
		my $s3duplicateDestination = $pre . "_" . $weekOfTheMonth . $post;
		$bucket->copy_key($s3duplicateDestination, $currentS3Key);
	}
	if($rollingBackups =~ m/month/) {
		my $s3duplicateDestination = $pre . "_" . $monthOfTheYear . $post;
		$bucket->copy_key($s3duplicateDestination, $currentS3Key);
	}
	if($rollingBackups =~ m/year/) {
		my $s3duplicateDestination = $pre . "_" . $yearValue . $post;
		$bucket->copy_key($s3duplicateDestination, $currentS3Key);
	}
}

sub createDayOfWeekCopies {
	# what we're doing here is copying this backup to a file with the name of a day of the week.
	copy($zipoutput, $dayofweekzipoutput);
	
	# add the day of the week file to the list to send
	push @filesToSend, $dayofweekzipoutput;
}


sub sendEmails {
	print "About to send emails\n";
	if($#emailAddresses < 0 ) {
		# this means there are no email addresses specified
		print "No email addresses specified\n";
		return;
	}
	if((isBlank($emailServer) || isBlank($emailServerUser) || isBlank($emailServerPassword))) {
		print "One of the email server variables is blank so emails cannot be sent $emailServer, $emailServerUser, $emailServerPassword.\n";
		return;
	}
	
	foreach my $emailAddress (@emailAddresses) {	
		$smtp = Net::SMTP_auth->new($emailServer, Debug => 0);
		if($smtp->auth('LOGIN', $emailServerUser, $emailServerPassword) ) {
			$smtp->mail($emailFrom);
			$smtp->recipient($emailAddress);
			  
			$smtp->data(composeBackupMessage($emailAddress));
			$smtp->dataend();
		}
		else {
			print "Could not connect to email server.\n";
		}
		
		$smtp->quit;
	}
}


sub composeBackupMessage {
	my $emailAddress = shift;
	my @lines =
	
	(
		"To: $emailAddress",
		"From: " . $emailFrom,
		'Subject: Backup Report',
		''
	);
	
	push @lines, @emailMessages;
	

	my $msg = join "\n", @lines;
	return $msg;
}


sub isBlank {
	
	my $value = shift;
	unless($value) {
		return "true";
	}
	
	if($value eq '') {
		return "true";
	}
	
	return undef;
}
