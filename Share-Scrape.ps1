<#---------------------------HELP INFORMATION--------------------------------#
.Synopsis
   Scrapes the Domain Global Catolog server for all computer objects and tests
   Access permissions to any shares that are identified on those servers
   Outputs results into a csv file

.DESCRIPTION
    The script takes a list of domains and identifies the nearest Global Catalog
    server to query for all computer objects. This query can either be paged or
    limited to 1000 results
    The computer objects are then tested to see if there are openshares available
    And each share is enumerated for permissions per user/group object
    The results are then returned to the main funciton and stripped of the 
    workflow information and exported to a CSV document

.PARAMETER
    -file <path to SIS CSV File>

.EXAMPLE
    #Add or remove domains as you want, empty string == just dns root of the domain
    $domain_list =  @('test', 'dev', '')
    $gc_list = [System.Collections.ArrayList]::new()
    foreach ($d in $domain_list)
    {
        $gc_list.Add((Get-GlobalCatologs -domain $d -dns_root "contso.corp.com"))
    }

    $result = Get-Servers -gc_list $gc_list | select * -ExcludeProperty PS*
    $permissions = Test-servers -server_list (($result.properties).dnshostname)
    $permissions | select * -ExcludeProperty PS* | Export-Csv -Path c:/temp/domain_scrape_result.csv -NoTypeInformation
   
.INPUTS
   Inputs are Domains you want to search
   Output File Name
   If you want paging enabled

.OUTPUTS
    CSV document specifying if the FQDN has an open share and all permissions
    the share has
#----------------------------------------------------------------------------#>

Workflow Get-Servers
{
  param(
    $gc_list
  )
    foreach -parallel ($gc in $gc_list) {
        Sequence
        {
            InlineScript
            {
                #this is much faster then loading AD Module in each spawned process when using workflows
                #Basically creating a raw LDAP connection as opposed to loading and unloading the AD module for every process
                $ErrorActionPreference = "SilentlyContinue"
                $de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://"+$using:gc)
                $ds = New-Object System.DirectoryServices.DirectorySearcher
                $ds.SearchRoot = $de
                $ds.Filter = "(&(objectCategory=computer)(objectClass=computer)(Name=*))"

                #Windows Directory Services limits its results to 1000 items unless you tell it to page your results
                #Keep page size no more than 1000
                #$ds.PageSize = 1000

                $ds.SearchScope = "SubTree"
                $retval = $ds.FindAll()
                Return $retval
            }#End InlineScript
        }#End Sequence
    }#End ForEach Parallel
}#End Workflow

#--------------------------------Test-Server Workflow----------------------------------#
Workflow Test-servers
{
    #List of servers to be tested for access
    param(
        $server_list
    )

    #This is the bread and butter to create the multithreaded work
    foreach -parallel ($server in $server_list)
    {
        InlineScript
        {
            #Creates a "net view object with error redirection" this object is just plain ascii text
            #the server will only respond if domain joined but so will having read access to the shares ;)
            $net = (net view $using:server /all 2>&1)
            $result_array = @()
            if ($LASTEXITCODE -eq 0) 
            {
                #Parse out all shares from the net view ascii soup, condenced the original line down to a regex match that 
                #replace spaces with ',' and grabs the first element which is the share name
                #this will feed the for loop and enumerate all shares on a host
                #https://stackoverflow.com/questions/38687890/net-view-get-just-share-name
                foreach ($share in (($net| Where-Object { $_ -match '\sDisk\s' }) -replace '\s\s+', ',' | ForEach-Object{ ($_ -split ',')[0] }))
                {
                    try 
                    {
                        #Checks the access for each share and create an "access object"
                        $access = (get-acl -ErrorAction Stop \\$using:server\$share).access
                        
                        #Get-ACL does not inlcude the name of the server in the acl object so I modify the object and add in the server and share
                        foreach($a in $access)
                        {
                            Add-Member -InputObject $a -NotePropertyName Share -NotePropertyValue "\\$using:server\$share" 
                            $result_array += $a.Psobject.Copy()
                            Write-Host -ForegroundColor Green "READ Access to \\$using:server\$share"
                        }
                    }catch
                    {
                        #Currently not including shares in the results where we have no access to reduce noise
                        #left code here for future use
                        Write-Host -ForegroundColor Red " No READ Access to \\$using:server\$share"
                    }
                }
            } else 
            {
                if ($net -like "*error 53*"){
                    Write-Host -ForegroundColor Red " Host $using:server is either offline, firewalled"
                } else 
                {
                    Write-Host -ForegroundColor Red " Host $using:server is likely not Windows"
                }
            }#End If-Else

            #No code left to run, just return results from this forked process
            Return $result_array
        }#End InlineScript
    }#End ForEach -Parallel
}#End WorkFlow
#--------------------------------End Test-Server Workflow----------------------------------#

#--------------------------------Test Conn Workflow----------------------------------#
#Simultaniously gets and returns all connections to GC Domain controllers
Workflow Test-WFConnection {
  param(
    [string[]]$Computers
  )
  foreach -parallel ($computer in $computers) {
    Test-Connection -ComputerName $computer -Count 1 -ErrorAction SilentlyContinue
  }
}
#--------------------------------End Test Conn Workflow----------------------------------#


#--------------------------------Closest Server----------------------------------#
#Picks the closest GC based on response time
Function Get-ClosestServer{  
    param(
    [string[]]$Computers
    )
    Write-Host "... Now Finding Closest GC Server for $SearchRoot"
    $PingInfo = Test-WFConnection $Computers
 
    #get system with lowest responsetime
    $PingInfo | sort-object ResponseTime | select -expandproperty address -First 1
}
#--------------------------------End Closest Server----------------------------------#


#--------------------------------Get-GlobalCatolog Server----------------------------------#
Function Get-GlobalCatologs
{
    param(
        $domain,
        $dns_root
    )
    #Use DNSRoot of local domain as server name for UseMyDomain
    #The AD forest domain is used by default
    if([string]::IsNullOrEmpty($domain))
    {
        $SearchRoot = $dns_root
    }else
    {
        $SearchRoot = "$domain.$dns_root"
    }
    #Get a list of GCs in the parent domain
    Write-Host "Getting list of all GC Server(s) for $SearchRoot"
    $gc = get-addomaincontroller -server $SearchRoot -Filter { isGlobalCatalog -eq $true}

    if ($gc.count -eq 0)
    {
       Write-Warning "No Global Catalog Server found in $SearchRoot"
       $server = $SearchRoot
    }ELSE{
        #This syntax handles result whether or not it is an array
        $server = Get-ClosestServer $gc.hostname
    }
    Return $server
}
#--------------------------------End Get-GlobalCatolog Server----------------------------------#

#Add or remove domains as you want, empty string == -dns_root
$domain_list =  @('')
$gc_list = [System.Collections.ArrayList]::new()
foreach ($d in $domain_list)
{
    $gc_list.Add((Get-GlobalCatologs -domain $d -dns_root "wargames.binns"))
}

$result = Get-Servers -gc_list $gc_list | select * -ExcludeProperty PS*
$permissions = Test-servers -server_list (($result.properties).dnshostname)
$permissions |select * -ExcludeProperty PS* | Export-Csv -Path ./domain_scrape_result.csv -NoTypeInformation