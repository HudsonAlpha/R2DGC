#' Takes a vector of paths to input files and aligns common metabolites into a final table.  Will also identify metabolites if a reference library is provided

#' @param inputFileList Vector of file paths to align
#' @param RT1_Standards Vector of standard names used to adjust first retention time. All names must be found in input files. Set to c() to avoid using RT adjustment. Defaults to FAME_8-24.
#' @param RT2_Standards Vector of standard names used to adjust second retention time. All names must be found in input files. Set to c() to avoid using RT adjustment. Defaults to empty vector.
#' @param seedFile File number in inputFileList to initialize alignment. Can also input a vector of different seed files (3 is usually sufficient) to prevent bias from seed file.  Defaults to 1.
#' @param RT1Penalty Penalty used for first retention time errors.  Defaults to 1.
#' @param RT2Penalty Penalty used for first retention time errors.  Defaults to 10.
#' @param autoTuneMatchStringency Will automatically find optimal match threshold. If TRUE, will ignore similarityCutoff. Defaults to TRUE.
#' @param similarityCutoff Adjusts peak similarity threshold required for alignment. Adjust in concordance with RT1 and RT2 penalties. Will be ignored if autoTuneMatchStrigency is TRUE. Defaults to 90.
#' @param disimilarityCutoff Defaults to similarityCutoff-90. Sets the threshold for including a new peak in the alignment table to ensure new metabolites aren't just below alignment thresholds
#' @param numCores Number of cores used to parallelize alignment. See parallel package. Defaults to 4.
#' @param commonIons Provide a vector of ions to ignore from the FindProblemIons function. Defaults to empty vector.
#' @param missingValueLimit Maximum fraction (Numeric between 0 and 1) of missing values acceptable for retaining a metabolite in the final alignment table. Defaults to 0.25.
#' @param missingPeakFinderSimilarityLax Fraction of Similarity Cutoff to use to find missing alignments just below threshold. Set to 1 to prevent searching for missing peaks. Defaults to 0.85.
#' @param quantMethod Set to U, A, or T to indicate if unique mass (U), appexing masses (A), or total ion chormatograph (T) was used to quantify peak areas. Defaults to T.  If "T" or "A", peaks meeting similarity thresholds will simply be summed. If "U", peaks with the same unique mass with be summed and a proportional conversion will be used before combining peaks with different unique masses.
#' @param standardLibrary Defaults to NULL. Provide standard library generated from MakeReference function to ID metabolites with retention index.

#' @return A list with three items: AlignmentMatix - A dataframe with peak areas for all metabolites matched in sufficient number of samples. MetaboliteInfo - An info file with RT, spectra, and metabolite ID info for each metabolite in the AlignmentMatrix. UnmatchedQuantMasses- Info on metabolites combined that had different unique masses (if quantMethod="U") or greater than 50% different apexing masses (if quantMethod="A")
#' @import parallel
#' @export
#' @examples
#' ConsensusAlign(c(system.file("extdata", "SampleA.txt", package="R2DGC"),
#'     system.file("extdata", "SampleB.txt", package="R2DGC")), RT1_Standards= c())

ConsensusAlign<-function(inputFileList,
                         RT1_Standards=paste("FAME_", seq(8,24,2), sep=""),
                         RT2_Standards=c(),
                         seedFile=1, #Change to 5 for test case reproducibility
                         RT1Penalty=1,
                         RT2Penalty=10, #1 for relatively unstable spectras
                         autoTuneMatchStringency=TRUE,
                         similarityCutoff=90,
                         disimilarityCutoff=similarityCutoff-90,
                         numCores=1,
                         commonIons=c(),
                         missingValueLimit=0.75,
                         missingPeakFinderSimilarityLax=0.85,
                         quantMethod="T",
                         standardLibrary=NULL){
  require(parallel)

  AlignmentTableList<-list()
  for(seed in seedFile){
    message(paste(seed, "seed"))
    #Read in and format seed file
    seedRawFile<-read.table(inputFileList[seed], sep="\t", fill=T, quote="",strip.white = T, stringsAsFactors = F,header=T)
    seedRawFile[,4]<-as.character(seedRawFile[,4])
    seedRawFile<-seedRawFile[which(!is.na(seedRawFile[,3])&nchar(seedRawFile[,4])!=0),]
    seedRawFile[,2]<-as.character(seedRawFile[,2])

    #Parse seed file retention time
    RTSplit<-data.frame(strsplit(seedRawFile[,2], " , "), stringsAsFactors = F)
    RTSplit[1,]<-gsub("\"", "", RTSplit[1,])
    RTSplit[2,]<-gsub("\"", "", RTSplit[2,])
    seedRawFile[,"RT1"]<-as.numeric(t(RTSplit[1,]))
    seedRawFile[,"RT2"]<-as.numeric(t(RTSplit[2,]))

    #Index metabolites by RT1 Standards
    if(length(RT1_Standards)>0){

      #Check if all RT1 standards are present in each file
      if(sum(RT1_Standards%in%seedRawFile[,1])!=length(RT1_Standards)){
        message(paste("Seed file missing RT1 standards:",RT1_Standards[which(!RT1_Standards%in%seedRawFile[,1])],sep=" "))
        break
      }

      #Index each metabolite by RT1 Standards
      RT1_Length<-max(seedRawFile[which(seedRawFile[,1]%in%RT1_Standards),6])-min(seedRawFile[which(seedRawFile[,1]%in%RT1_Standards),6])
      for(Standard in RT1_Standards){
        seedRawFile[,paste(Standard,"RT1",sep="_")]<-(seedRawFile[,6]-seedRawFile[grep(Standard,seedRawFile[,1],perl = T),6])/RT1_Length
      }
    }

    #Index metabolites by RT2 Standards
    if(length(RT2_Standards)>0){

      #Check if all RT2_Standards are present
      if(sum(RT2_Standards%in%seedRawFile[,1])!=length(RT2_Standards)){
        message(paste("Seed file missing RT2 standards:",RT2_Standards[which(!RT2_Standards%in%seedRawFile[,1])],sep=" "))
        break
      }

      #Index each metabolite by RT2 standards
      RT2_Length<-max(seedRawFile[which(seedRawFile[,1]%in%RT2_Standards),6])-min(seedRawFile[which(seedRawFile[,1]%in%RT2_Standards),6])
      for(Standard in RT2_Standards){
        seedRawFile[,paste(Standard,"RT2",sep="_")]<-(seedRawFile[,6]-seedRawFile[grep(Standard,seedRawFile[,1],perl = T),6])/RT2_Length
      }
    }

    #Parse seed file metabolite spectra
    currentRawFileSplit<-split(seedRawFile,1:nrow(seedRawFile))
    SeedspectraSplit<-lapply(currentRawFileSplit, function(a) strsplit(a[[4]]," "))
    SeedspectraSplit<-lapply(SeedspectraSplit, function(b) lapply(b, function(c) strsplit(c,":")))
    SeedspectraSplit<-lapply(SeedspectraSplit, function(d) t(matrix(unlist(d),nrow=2)))
    SeedspectraSplit<-lapply(SeedspectraSplit, function(d) d[order(d[,1]),])
    SeedspectraSplit<-lapply(SeedspectraSplit, function(d) d[which(!d[,1]%in%commonIons),])
    SeedspectraSplit<-lapply(SeedspectraSplit, function(d) apply(d,2,as.numeric))

    #Establish alignment matrix
    FinalMatrix<-matrix(nrow=nrow(seedRawFile),ncol=length(inputFileList))
    row.names(FinalMatrix)<-seedRawFile[,1]
    colnames(FinalMatrix)<-inputFileList
    FinalMatrix[,inputFileList[seedFile]]<-seedRawFile[,3]

    #Establish emptly list to store incongruent quant matches if using quantMethod "U" or "A"
    MissingQMList<-list()
    #Establish empty list to store similarity score matrices for each file
    SimCutoffs<-list()
    #Establish empty list to store parsed files
    RawFileList<-list()
    #Create empty list for missing retention indices
    MissingRTIndices<-list()

    #Loop through non seed files
    message("Computing pairwise alignments")
    for(File in inputFileList[-seed]){

      #Read in file
      currentRawFile<-read.table(File, sep="\t", fill=T, quote="",strip.white = T, stringsAsFactors = F,header=T)
      currentRawFile[,4]<-as.character(currentRawFile[,4])
      currentRawFile<-currentRawFile[which(!is.na(currentRawFile[,3])&nchar(currentRawFile[,4])!=0),]
      currentRawFile[,2]<-as.character(currentRawFile[,2])

      #Parse retention times
      RTSplit<-data.frame(strsplit(currentRawFile[,2], " , "), stringsAsFactors = F)
      RTSplit[1,]<-gsub("\"", "", RTSplit[1,])
      RTSplit[2,]<-gsub("\"", "", RTSplit[2,])
      currentRawFile[,"RT1"]<-as.numeric(t(RTSplit[1,]))
      currentRawFile[,"RT2"]<-as.numeric(t(RTSplit[2,]))

      #Index metabolites by RT1 standards
      if(length(RT1_Standards)>0){
        #Check if all RT1 standards are present
        if(sum(RT1_Standards%in%currentRawFile[,1])!=length(RT1_Standards)){
          MissingRTIndices[[File]]<-RT1_Standards[which(!RT1_Standards%in%currentRawFile[,1])]
          next
        }
        #Index each metabolite by RT1 standards
        RT1_Length<-max(currentRawFile[which(currentRawFile[,1]%in%RT1_Standards),6])-min(currentRawFile[which(currentRawFile[,1]%in%RT1_Standards),6])
        for(Standard in RT1_Standards){
          currentRawFile[,paste(Standard,"RT1",sep="_")]<-(currentRawFile[,6]-currentRawFile[grep(Standard,currentRawFile[,1],perl = T),6])/RT1_Length
        }
      }

      #Index metabolites by RT2 standards
      if(length(RT2_Standards)>0){
        #Check if all RT2 standards are present
        if(sum(RT2_Standards%in%currentRawFile[,1])!=length(RT2_Standards)){
          MissingRTIndices[[File]]<-RT2_Standards[which(!RT2_Standards%in%currentRawFile[,1])]
          next
        }
        #Index each metabolite by RT2 standards
        RT2_Length<-max(seedRawFile[which(seedRawFile[,1]%in%RT2_Standards),6])-min(seedRawFile[which(seedRawFile[,1]%in%RT2_Standards),6])
        for(Standard in RT2_Standards){
          seedRawFile[,paste(Standard,"RT2",sep="_")]<-(seedRawFile[,6]-seedRawFile[grep(Standard,seedRawFile[,1],perl = T),6])/RT2_Length
        }
      }

      #Parse metabolite spectra
      currentRawFileSplit<-split(currentRawFile,1:nrow(currentRawFile))
      spectraSplit<-lapply(currentRawFileSplit, function(a) strsplit(a[[4]]," "))
      spectraSplit<-lapply(spectraSplit, function(b) lapply(b, function(c) strsplit(c,":")))
      spectraSplit<-lapply(spectraSplit, function(d) t(matrix(unlist(d),nrow=2)))
      spectraSplit<-lapply(spectraSplit, function(d) d[order(d[,1]),])
      spectraSplit<-lapply(spectraSplit, function(d) d[which(!d[,1]%in%commonIons),])
      spectraSplit<-lapply(spectraSplit, function(d) apply(d,2,as.numeric))

      #Calculate pairwise metabolite similarity scores for each current file metabolite with seed file metabolites
      SimilarityScores<-mclapply(spectraSplit, function(e) lapply(SeedspectraSplit, function(d) ((e[,2]%*%d[,2])/(sqrt(sum(e[,2]*e[,2]))*sqrt(sum(d[,2]*d[,2]))))*100), mc.cores=numCores)
      SimilarityMatrix<-matrix(unlist(SimilarityScores), nrow=nrow(seedRawFile))

      #Calculate pairwise RT penalties for each current file metabolite and seed file metabolites
      RT1Index<-matrix(unlist(lapply(currentRawFile[,6],function(x) abs(x-seedRawFile[,6])*RT1Penalty)),nrow=nrow(seedRawFile))
      RT2Index<-matrix(unlist(lapply(currentRawFile[,7],function(x) abs(x-seedRawFile[,7])*RT2Penalty)),nrow=nrow(seedRawFile))

      #Use RT indices to calculate RT penalties if necessary
      if(length(RT1_Standards)>0){
        #Compute list of metabolite to RT1 standard differences between current file and seed file for each metabolite
        RT1Index<-list()
        for(Standard in RT1_Standards){
          RT1Index[[Standard]]<-matrix(unlist(lapply(currentRawFile[,paste(Standard,"RT1",sep="_")],function(x) abs(x-seedRawFile[,paste(Standard,"RT1",sep="_")])*(RT1Penalty/length(RT1_Standards)))),nrow=nrow(seedRawFile))*RT1_Length
        }
        #Sum all relative standard differences into a final score
        RT1Index<-Reduce("+",RT1Index)
      }
      if(length(RT2_Standards)>0){
        #Compute list of metabolite to RT2 standard differences between current file and seed file for each metabolite
        RT2Index<-list()
        for(Standard in RT2_Standards){
          RT2Index[[Standard]]<-matrix(unlist(lapply(currentRawFile[,paste(Standard,"RT2",sep="_")],function(x) abs(x-seedRawFile[,paste(Standard,"RT2",sep="_")])*(RT2Penalty/length(RT2_Standards)))),nrow=nrow(seedRawFile))*RT2_Length
        }
        #Sum all relative standard differences into a final score
        RT2Index<-Reduce("+",RT2Index)
      }

      #Subtract final retention time penalties and store similarity scores in SimCutoffs
      SimCutoffs[[File]]<-SimilarityMatrix-RT1Index-RT2Index
      #Store parsed raw file in RawFileList
      RawFileList[[File]]<-currentRawFile
    }

    #Error if missing RT indices are present
    if(length(MissingRTIndices)>0){
      message("Error: Missing RT indices detected. See output list")
      return(MissingRTIndices)
      break
    }

    #Calculate optimal similarity score cutoff if desired
    if(autoTuneMatchStringency==TRUE){
      message("Computing peak similarity threshold")
      SimScores<-mclapply(SimCutoffs, function(y) unlist(lapply(1:100,function(x) sum(rowSums(y>x)>0)/(sum(y>x)^0.5))),mc.cores = numCores)
      SimScores<-matrix(unlist(SimScores),ncol=length(SimScores))
      similarityCutoff<-which.max(rowSums(SimScores))
    }

    #Loop back through input files and find matches above similarityCutoff threshold
    for(File in inputFileList[-seed]){
      currentRawFile<-RawFileList[[File]]

      #Find best matches and mate pairs for each metabolite and remove inferior matches if metabolite is matched twice
      MatchScores<-apply(SimCutoffs[[File]],2,function(x) max(x,na.rm=T))
      Mates<-apply(SimCutoffs[[File]],2,function(x) which.max(x))
      names(MatchScores)<-1:length(MatchScores)
      names(Mates)<-1:length(Mates)
      Mates<-Mates[order(-MatchScores)]
      MatchScores<-MatchScores[order(-MatchScores)]
      MatchScores[which(duplicated(Mates))]<-NA
      Mates<-Mates[order(as.numeric(names(Mates)))]
      MatchScores<-MatchScores[order(as.numeric(names(MatchScores)))]

      if(quantMethod=="U"){
        #Find quant masses for each match pair
        MatchedSeedQMs<- seedRawFile[,5][Mates[which(MatchScores>=similarityCutoff)]]
        currentFileQMs<- currentRawFile[which(MatchScores>=similarityCutoff),5]
        #Add incongruent quant mass info to MissingQMList for output
        MissingQMList[[File]]<-cbind(File,which(MatchScores>=similarityCutoff),currentFileQMs,inputFileList[seedFile],Mates[which(MatchScores>=similarityCutoff)],MatchedSeedQMs)[which(currentFileQMs!=MatchedSeedQMs),]
        #Convert areas proportionally for incongruent quant masses
        currentFileAreas<- currentRawFile[which(MatchScores>=similarityCutoff),3]
        currentFileSpectra<- spectraSplit[which(MatchScores>=similarityCutoff)]
        MatchedSeedSpectra<- SeedspectraSplit[Mates[which(MatchScores>=similarityCutoff)]]
        ConvNumerator<-unlist(lapply(1:length(currentFileQMs), function(x) currentFileSpectra[[x]][which(currentFileSpectra[[x]][,1]==currentFileQMs[x]),2]))
        ConvDenominator<-unlist(lapply(1:length(currentFileQMs), function(x) currentFileSpectra[[x]][which(currentFileSpectra[[x]][,1]==MatchedSeedQMs[x]),2]))
        ConvDenominator[which(ConvDenominator==0)]<-NA
        #Add matched peaks to final alignment matrix
        FinalMatrix[Mates[which(MatchScores>=similarityCutoff)],File]<-currentFileAreas*(ConvNumerator/ConvDenominator)
      }

      if(quantMethod=="A"){
        #Make function to parse apexing masses and test whether 50% are in common with seed file
        TestQMOverlap<-function(x){
          SeedQMs<- strsplit(x[1],"\\+")
          FileQMs<- strsplit(x[2],"\\+")
          sum(unlist(SeedQMs)%in%unlist(FileQMs))/min(length(unlist(SeedQMs)),length(unlist(FileQMs)))<0.5
        }
        #Test apexing mass overlap for each metabolite match
        MatchedSeedQMs<- seedRawFile[,5][Mates[which(MatchScores>=similarityCutoff)]]
        currentFileQMs<- currentRawFile[which(MatchScores>=similarityCutoff),5]
        QM_Bind<-cbind(MatchedSeedQMs,currentFileQMs)
        QM_Match<-apply(QM_Bind, 1, function(x) TestQMOverlap(x))
        #Add incongruent apexing masses to MissingQMList for output
        MissingQMList[[File]]<-cbind(File,which(MatchScores>=similarityCutoff),currentFileQMs,inputFileList[seedFile],Mates[which(MatchScores>=similarityCutoff)],MatchedSeedQMs)[which(QM_Match==TRUE),]
        #Add matched peaks to final alignment matrix
        FinalMatrix[Mates[which(MatchScores>=similarityCutoff)],File]<-currentRawFile[which(MatchScores>=similarityCutoff),3]
      }

      if(quantMethod=="T"){
        #Add newly aligned peaks to alignment matrix
        FinalMatrix[Mates[which(MatchScores>=similarityCutoff)],File]<-currentRawFile[which(MatchScores>=similarityCutoff),3]
      }

      #Find metabolites in current file sufficiently dissimilar to add to alignment matrix
      toAdd<-matrix(ncol=length(inputFileList),nrow=length(which(MatchScores<disimilarityCutoff)))
      colnames(toAdd)<-inputFileList
      row.names(toAdd)<- currentRawFile[which(MatchScores<disimilarityCutoff),1]
      toAdd[,File]<-currentRawFile[which(MatchScores<disimilarityCutoff),3]
      FinalMatrix<-rbind(FinalMatrix,toAdd)
      #Add new metabolite spectras to seed file spectra list
      seedRawFile<-rbind(seedRawFile,currentRawFile[which(MatchScores<disimilarityCutoff),])
      if(length(which(MatchScores<disimilarityCutoff))>0){
        SeedspectraSplit[(length(SeedspectraSplit)+1):(length(SeedspectraSplit)+length(which(MatchScores<disimilarityCutoff)))]<- spectraSplit[which(MatchScores<disimilarityCutoff)]
      }
    }

    #Filter final alignment matrix to only peaks passing the missing value limit
    seedRawFile<-seedRawFile[which(rowSums(is.na(FinalMatrix))<=round(length(inputFileList)*(1-missingValueLimit))),]
    FinalMatrix<-FinalMatrix[which(rowSums(is.na(FinalMatrix))<=round(length(inputFileList)*(1-missingValueLimit))),]

    #Compute relaxed similarity cutoff with missingPeakFinderSimilarityLax
    similarityCutoff<-similarityCutoff*missingPeakFinderSimilarityLax

    message("Searching for missing peaks")
    #Loop through each file again and check for matches in high probability missing metabolites meeting relaxed similarity cutoff
    for(File in inputFileList){

      #read in file
      currentRawFile<-read.table(File, sep="\t", fill=T, quote="",strip.white = T, stringsAsFactors = F, header=T)
      currentRawFile[,4]<-as.character(currentRawFile[,4])
      currentRawFile<-currentRawFile[which(!is.na(currentRawFile[,3])&nchar(currentRawFile[,4])!=0),]
      currentRawFile[,2]<-as.character(currentRawFile[,2])

      #Parse retention times
      RTSplit<-data.frame(strsplit(currentRawFile[,2], " , "), stringsAsFactors = F)
      RTSplit[1,]<-gsub("\"", "", RTSplit[1,])
      RTSplit[2,]<-gsub("\"", "", RTSplit[2,])
      currentRawFile[,"RT1"]<-as.numeric(t(RTSplit[1,]))
      currentRawFile[,"RT2"]<-as.numeric(t(RTSplit[2,]))

      #Find peaks with missing values
      MissingPeaks<-which(is.na(FinalMatrix[,File]))
      if(length(MissingPeaks)>0){

        #Calculate RT1 standard indices
        if(length(RT1_Standards)>0){
          RT1_Length<-max(currentRawFile[which(currentRawFile[,1]%in%RT1_Standards),6])-min(currentRawFile[which(currentRawFile[,1]%in%RT1_Standards),6])
          for(Standard in RT1_Standards){
            currentRawFile[,paste(Standard,"RT1",sep="_")]<-(currentRawFile[,6]-currentRawFile[grep(Standard,currentRawFile[,1],perl = T),6])/RT1_Length
          }
        }

        #Calculate RT2 standard indices
        if(length(RT2_Standards)>0){
          RT2_Length<-max(seedRawFile[which(seedRawFile[,1]%in%RT2_Standards),6])-min(seedRawFile[which(seedRawFile[,1]%in%RT2_Standards),6])
          for(Standard in RT2_Standards){
            seedRawFile[,paste(Standard,"RT2",sep="_")]<-(seedRawFile[,6]-seedRawFile[grep(Standard,seedRawFile[,1],perl = T),6])/RT2_Length
          }
        }

        #Parse metabolite spectra
        currentRawFileSplit<-split(currentRawFile,1:nrow(currentRawFile))
        spectraSplit<-lapply(currentRawFileSplit, function(a) strsplit(a[[4]]," "))
        spectraSplit<-lapply(spectraSplit, function(b) lapply(b, function(c) strsplit(c,":")))
        spectraSplit<-lapply(spectraSplit, function(d) t(matrix(unlist(d),nrow=2)))
        spectraSplit<-lapply(spectraSplit, function(d) d[order(d[,1]),])
        spectraSplit<-lapply(spectraSplit, function(d) d[which(!d[,1]%in%commonIons),])
        spectraSplit<-lapply(spectraSplit, function(d) apply(d,2,as.numeric))

        #Compute pairwise similarity scores
        SimilarityScores<-mclapply(spectraSplit, function(e) lapply(SeedspectraSplit[MissingPeaks], function(d) ((e[,2]%*%d[,2])/(sqrt(sum(e[,2]*e[,2]))*sqrt(sum(d[,2]*d[,2]))))*100), mc.cores=numCores)
        SimilarityMatrix<-matrix(unlist(SimilarityScores), nrow=length(MissingPeaks))

        #Compute RT differences
        RT1Index<-matrix(unlist(lapply(currentRawFile[,6],function(x) abs(x-seedRawFile[MissingPeaks,6])*RT1Penalty)),nrow=nrow(seedRawFile[MissingPeaks,]))
        RT2Index<-matrix(unlist(lapply(currentRawFile[,7],function(x) abs(x-seedRawFile[MissingPeaks,7])*RT2Penalty)),nrow=nrow(seedRawFile[MissingPeaks,]))

        #Use RT indices to calculate RT differences
        if(length(RT1_Standards)>0){
          RT1Index<-list()
          for(Standard in RT1_Standards){
            RT1Index[[Standard]]<-matrix(unlist(lapply(currentRawFile[,paste(Standard,"RT1",sep="_")],function(x) abs(x-seedRawFile[MissingPeaks,paste(Standard,"RT1",sep="_")])*(RT1Penalty/length(RT1_Standards)))),nrow=nrow(seedRawFile[MissingPeaks,]))*RT1_Length
          }
          RT1Index<-Reduce("+",RT1Index)
        }
        if(length(RT2_Standards)>0){
          RT2Index<-list()
          for(Standard in RT2_Standards){
            RT2Index[[Standard]]<-matrix(unlist(lapply(currentRawFile[,paste(Standard,"RT2",sep="_")],function(x) abs(x-seedRawFile[,paste(Standard,"RT2",sep="_")])*(RT2Penalty/length(RT2_Standards)))),nrow=nrow(seedRawFile))*RT2_Length
          }
          RT2Index<-Reduce("+",RT2Index)
        }

        #Subtract RT penalty from similarity scores
        SimilarityMatrix<-SimilarityMatrix-RT1Index-RT2Index

        #Find top matches for each metabolite and remove duplicates if a metabolite matches multiple times
        MatchScores<-apply(SimilarityMatrix,2,function(x) max(x,na.rm=T))
        Mates<-apply(SimilarityMatrix,2,function(x) which.max(x))
        names(MatchScores)<-1:length(MatchScores)
        names(Mates)<-1:length(Mates)
        Mates<-Mates[order(-MatchScores)]
        MatchScores<-MatchScores[order(-MatchScores)]
        MatchScores[which(duplicated(Mates))]<-NA
        Mates<-Mates[order(as.numeric(names(Mates)))]
        MatchScores<-MatchScores[order(as.numeric(names(MatchScores)))]
        Mates<-MissingPeaks[Mates]

        #If matches are greater than relaxed simlarity cutoff add to final alignment table
        if(length(which(MatchScores>=similarityCutoff))>0){
          if(quantMethod=="U"){
            #Find quant masses for each match pair
            MatchedSeedQMs<- seedRawFile[,5][Mates[which(MatchScores>=similarityCutoff)]]
            currentFileQMs<- currentRawFile[which(MatchScores>=similarityCutoff),5]
            #Add incongruent quant mass info to MissingQMList for output
            MissingQMList[[paste0(File,"_MPF")]]<-cbind(File,which(MatchScores>=similarityCutoff),currentFileQMs,inputFileList[seedFile],Mates[which(MatchScores>=similarityCutoff)],MatchedSeedQMs)[which(currentFileQMs!=MatchedSeedQMs),]
            #Convert areas proportionally for incongruent quant masses
            currentFileAreas<- currentRawFile[which(MatchScores>=similarityCutoff),3]
            currentFileSpectra<- spectraSplit[which(MatchScores>=similarityCutoff)]
            MatchedSeedSpectra<- SeedspectraSplit[Mates[which(MatchScores>=similarityCutoff)]]
            ConvNumerator<-unlist(lapply(1:length(currentFileQMs), function(x) currentFileSpectra[[x]][which(currentFileSpectra[[x]][,1]==currentFileQMs[x]),2]))
            ConvDenominator<-unlist(lapply(1:length(currentFileQMs), function(x) currentFileSpectra[[x]][which(currentFileSpectra[[x]][,1]==MatchedSeedQMs[x]),2]))
            ConvDenominator[which(ConvDenominator==0)]<-NA
            #Add matched peaks to final alignment matrix
            FinalMatrix[Mates[which(MatchScores>=similarityCutoff)],File]<-currentFileAreas*(ConvNumerator/ConvDenominator)
          }
          if(quantMethod=="A"){
            #Make function to parse apexing masses and test whether 50% are in common with seed file
            TestQMOverlap<-function(x){
              SeedQMs<- strsplit(x[1],"\\+")
              FileQMs<- strsplit(x[2],"\\+")
              return(sum(unlist(SeedQMs)%in%unlist(FileQMs))/min(length(unlist(SeedQMs)),length(unlist(FileQMs)))<0.5)
            }
            #Test apexing mass overlap for each metabolite match
            MatchedSeedQMs<- seedRawFile[,5][Mates[which(MatchScores>=similarityCutoff)]]
            currentFileQMs<- currentRawFile[which(MatchScores>=similarityCutoff),5]
            QM_Bind<-cbind(MatchedSeedQMs,currentFileQMs)
            QM_Match<-apply(QM_Bind, 1, function(x) TestQMOverlap(x))
            #Add incongruent apexing masses to MissingQMList for output
            MissingQMList[[paste0(File,"_MPF")]]<-cbind(File,which(MatchScores>=similarityCutoff),currentFileQMs,inputFileList[seedFile],Mates[which(MatchScores>=similarityCutoff)],MatchedSeedQMs)[which(QM_Match==TRUE),]
            #Add matched peaks to final alignment matrix
            FinalMatrix[Mates[which(MatchScores>=similarityCutoff)],File]<-currentRawFile[which(MatchScores>=similarityCutoff),3]
          }
          if(quantMethod=="T"){
            #Add matched peaks to final alignment matrix
            FinalMatrix[Mates[which(MatchScores>=similarityCutoff)],File]<-currentRawFile[which(MatchScores>=similarityCutoff),3]
          }
        }
      }
    }
    #Make MissingQMList into dataframe for output
    MissingQMFrame<-do.call(rbind,MissingQMList)
    AlignmentTableList[[as.character(seed)]]<-FinalMatrix
  }

  #If only one seed file is provided just output alignment matrix
  if(length(seedFile)==1){
    FinalMatrix<-AlignmentTableList[[1]]
  }

  #If multiple seed files provided find peaks with >50% overlap across all seed files
  if(length(seedFile)>1){

    #
    ConsensusPeaks<-list()
    ConsensusMatches<-list()
    for(i in 1:(length(AlignmentTableList)-1)){
      Overlaps<-apply(AlignmentTableList[[i]], 1, function(y) apply(AlignmentTableList[[length(AlignmentTableList)]], 1, function(x) sum(x%in%y, na.rm = T)))
      Indexes<-arrayInd(which(Overlaps>12), dim(Overlaps))
      row.names(Indexes)<-Indexes[,1]
      ConsensusPeaks[[i]]<-Indexes[,1]
      ConsensusMatches[[i]]<-Indexes
    }

    ConsensusPeaks<-Reduce(intersect, ConsensusPeaks)

    AlignmentTableListFilt<-AlignmentTableList
    for(i in 1:(length(AlignmentTableList)-1)){
      AlignmentTableListFilt[[i]]<-AlignmentTableListFilt[[i]][ConsensusMatches[[i]][as.character(ConsensusPeaks),2],inputFileList]
    }
    AlignmentTableListFilt[[length(AlignmentTableListFilt)]]<-AlignmentTableListFilt[[length(AlignmentTableListFilt)]][ConsensusPeaks,inputFileList]

    AlignVector<-data.frame(lapply(AlignmentTableListFilt, as.vector))
    FinalMatrix<-matrix(apply(AlignVector,1,function(x) median(x, na.rm=T)), nrow = length(ConsensusPeaks))
    colnames(FinalMatrix)<-inputFileList
    row.names(FinalMatrix)<- row.names(AlignmentTableListFilt[[length(AlignmentTableListFilt)]])
  }
  #Add metabolite IDs if standardLibrary is used
  if(!is.null(standardLibrary)){
    message("Matching peaks to standard library")

    #Parse seed file spectras
    peakSplit<-split(seedRawFile,1:nrow(seedRawFile))
    peakSpectraSplit<-lapply(peakSplit, function(a) strsplit(a[[4]]," "))
    peakSpectraSplit<-lapply(peakSpectraSplit, function(b) lapply(b, function(c) strsplit(c,":")))
    peakSpectraSplit<-lapply(peakSpectraSplit, function(d) t(matrix(unlist(d),nrow=2)))
    peakSpectraSplit<-lapply(peakSpectraSplit, function(d) d[order(d[,1]),])
    peakSpectraSplit<-lapply(peakSpectraSplit, function(d) d[which(!d[,1]%in%commonIons),])
    peakSpectraSplit<-lapply(peakSpectraSplit, function(d) apply(d,2,as.numeric))

    #Parse standard library spectras
    standardSplit<-split(standardLibrary,1:nrow(standardLibrary))
    standardSpectraSplit<-lapply(standardSplit, function(a) strsplit(a[[3]]," "))
    standardSpectraSplit<-lapply(standardSpectraSplit, function(b) lapply(b, function(c) strsplit(c,":")))
    standardSpectraSplit<-lapply(standardSpectraSplit, function(d) t(matrix(unlist(d),nrow=2)))
    standardSpectraSplit<-lapply(standardSpectraSplit, function(d) d[order(d[,1]),])
    standardSpectraSplit<-lapply(standardSpectraSplit, function(d) d[which(!d[,1]%in%commonIons),])
    standardSpectraSplit<-lapply(standardSpectraSplit, function(d) apply(d,2,as.numeric))

    #Calculate pairwise similarity scores
    SimilarityScores<-mclapply(peakSpectraSplit, function(e) lapply(standardSpectraSplit, function(d) ((e[,2]%*%d[,2])/(sqrt(sum(e[,2]*e[,2]))*sqrt(sum(d[,2]*d[,2]))))*100), mc.cores=numCores)
    SimilarityMatrix<-matrix(unlist(SimilarityScores), nrow=length(standardSpectraSplit))

    #Compute RT differences
    RT1Index<-matrix(unlist(lapply(seedRawFile[,6],function(x) abs(x-standardLibrary[,4])*RT1Penalty)),nrow=nrow(standardLibrary))
    RT2Index<-matrix(unlist(lapply(seedRawFile[,7],function(x) abs(x-standardLibrary[,5])*RT2Penalty)),nrow=nrow(standardLibrary))

    #Use RT indexes to compute RT differences
    if(length(RT1_Standards)>0){
      RT1Index<-list()
      for(Standard in RT1_Standards){
        RT1Index[[Standard]]<-matrix(unlist(lapply(seedRawFile[,paste(Standard,"RT1",sep="_")],function(x) abs(x-standardLibrary[,paste(Standard,"RT1",sep="_")])*(RT1Penalty/length(RT1_Standards)))),nrow=nrow(standardLibrary))*RT1_Length
      }
      RT1Index<-Reduce("+",RT1Index)
    }
    if(length(RT2_Standards)>0){
      RT2Index<-list()
      for(Standard in RT2_Standards){
        RT2Index[[Standard]]<-matrix(unlist(lapply(currentRawFile[,paste(Standard,"RT2",sep="_")],function(x) abs(x-seedRawFile[,paste(Standard,"RT2",sep="_")])*(RT2Penalty/length(RT2_Standards)))),nrow=nrow(seedRawFile))*RT2_Length
      }
      RT2Index<-Reduce("+",RT2Index)
    }

    #Subtract RT penalties from Similarity Scores
    SimilarityMatrix<-SimilarityMatrix-RT1Index-RT2Index
    row.names(SimilarityMatrix)<-standardLibrary[,1]

    #Append top three ID matches to each metabolite and scores to seedRaw for output
    seedRawFile<-cbind(t(apply(SimilarityMatrix,2,function(x) paste(names(x[order(-x)])[1:3],round(x[order(-x)][1:3],2),sep="_"))),seedRawFile)
  }
  returnList<-list(FinalMatrix, seedRawFile, MissingQMFrame)
  names(returnList)<-c("AlignmentMatrix","MetaboliteInfo","UnmatchedQuantMasses")
  return(returnList)
}