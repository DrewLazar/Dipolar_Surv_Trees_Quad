library(R6)
library(data.tree)
library(survival)
library(lpSolve)

QuadraticDipolarSurvivalTree = R6Class(
  
  classname = "QuadraticDipolarSurvivalTree",
  
  public = list(
    
    # MAIN DATA
    unaugmentedoriginal = NULL,
    traindata = NULL,
    originalrownames = NULL,
    covariates = NULL,
    covariatestoaugment = NULL,
    time = NULL,
    censor = NULL,
    poms = NULL,
    augmentedcovariates = NULL,
    allpairs = NULL,
    pureweight = NULL,
    mixedweight = NULL,
    
    # ALGORITHMS DATA
    quantiles = NULL, # cut-off quantiles to tag dipoles as "pure", "mixed", "neither"
    tolerance = NULL, # tolerance for reorientation algorithm convergence
    epsilon = NULL, # uniform margin for piecewise linear function
    quadmaxsum= NULL,
    quadmaxsum.scalebysize = NULL,
    
    # TREE DATA
    nsize = NULL, # terminal node size threshold
    
    # INITIALIZER
    initialize = function(
      traindata, time, censor, covariates, covariatestoaugment,
      quantiles = c(.35,.65), tolerance = 10^-3, epsilon = 1, nsize = 10,
      quadmaxsum = 10,
      pureweight = 1, mixedweight = 1,
      quadmaxsum.scalebysize = function(n) { n/nrow(self$traindata) },
      allpairs = TRUE
    ) {
      # Don't allow empty data sets
      if (!is.data.frame(traindata) || nrow(traindata) == 0) {
        stop("\"traindata\" variable must be a nonempty data frame")
      }
      traindata = traindata[c(time, censor, covariates)]
      self$unaugmentedoriginal = traindata
      # Rename rows of "traindata" to a sequence of consecutive integers
      # Store the original row names in case they are required later
      self$originalrownames = rownames(traindata)
      rownames(traindata) = seq(1:nrow(traindata))
      # Make sure the survival and covariate variable names are actually valid
      for (name in c(time, censor, covariates)) {
        if (!(name %in% names(traindata))) {
          stop(
            paste(name, "is not a variable in the data", sep = " ")
          )
        }
      }
      # Bulk initiation of various variables
      self$covariates = covariates
      self$covariatestoaugment = covariatestoaugment
      self$allpairs = allpairs
      if (!allpairs) {
        if (!is.list(covariatestoaugment)) {
          stop("covariatestoaugment must be list of pairs")
        }
        
        checklist = lapply(covariatestoaugment, function(v) {
          (length(v) == 2) && all(v %in% covariates)
        })
        
        if (any(checklist == FALSE)) {
          stop("covariatestoaugment must be pairs and elements must be in covariates")
        }
      }
      self$time = time
      self$censor = censor
      self$quantiles = quantiles
      self$tolerance = tolerance
      self$epsilon = epsilon
      self$nsize = nsize
      
      if (pureweight <= 0 || mixedweight <= 0) {
        stop("weights for dipoles must be positive")
      }
      self$pureweight = pureweight
      self$mixedweight = mixedweight
      # Create the "pure or mixed" matrix
      self$poms = self$createpoms(traindata)
      # A private constant used for the initial guess to get the optimizer started
      private$v0.default.index = if (length(covariates) >= 2) {
        2
      } else {
        1
      }
      
      # Quadratic augmentation of data
      self$traindata = self$augment.quadratic(traindata)
      
      #print(self$traindata)
      
      self$quadmaxsum = quadmaxsum
      self$quadmaxsum.scalebysize = quadmaxsum.scalebysize
      
      # Create the dipolar survival tree
      # fullX = traindata[covariates]
      # self$dipolarsurvivaltree = Node$new("Node0", data = fullX)
      # self$createtree(self$dipolarsurvivaltree)
      # 
      self$augmentedcovariates = self$augment.covariates()
    },
    
    
    # FOR QUADRATIC AUGMENTATION OF COVARIATES USE THIS INSTEAD:
    augment.quadratic = function(original){
      if(self$allpairs) {
        input = original[self$covariatestoaugment]
        augment <- do.call("cbind", lapply(1:ncol(input), FUN=function(z){
          do.call("cbind", lapply(z:ncol(input), FUN=function(x){
            tmp <- data.frame(input[,z] * input[,x])
            colnames(tmp)[1] <- paste(colnames(input)[z], ":", colnames(input)[x], sep="") # Multiplication symbol changed to : as per R style instead of x to avoid confusion with variables containing x
            tmp
          }))
        }))
        cbind(original, augment)
      } else {
        augment = lapply(self$covariatestoaugment, function(covpair) {
          covpair.data = original[covpair]
          covpair.interact = covpair.data[1]*covpair.data[2]
          names(covpair.interact) = paste(covpair, collapse = ":")
          covpair.interact
        })
        cbind(original, augment)
      }
    },
    
    
    augment.covariates  = function() {
      augcov = colnames(self$traindata)
      augcov = augcov[!(augcov %in% c(self$time, self$censor))]
      return(augcov)
    },
    
    
    # CREATE "PURE OR MIXED" MATRIX
    createpoms = function(data) {
      lowerQ = self$quantiles[1]
      upperQ = self$quantiles[2]
      # Make pairwise distance vector while accounting for censoring
      N = nrow(data)
      DT <- rep(NA, ceiling(N*N / 2))
      DTindex = 0
      for (i in 1:(N-1)) {
        # survival information of i-th data point
        xitime = data[i, self$time]
        xicensor = data[i, self$censor]
        for (j in (i+1):N) {
          # survival information of j-th data point
          xjtime = data[j, self$time]
          xjcensor = data[j, self$censor]
          # account for censoring as follows:
          if (
            (xicensor == 1) && (xjcensor == 1) ||
            ((xicensor == 0) && (xjcensor == 1) && (xitime > xjtime)) ||
            ((xicensor == 1) && (xjcensor == 0) && (xjtime > xitime))
          ) {
            DT[DTindex] = abs(xitime - xjtime)
            DTindex = DTindex + 1
          }
        }
      }
      # Get the lower and upper quantile cut-off thresholds
      QV = quantile(DT, c(lowerQ, upperQ), na.rm = TRUE)
      lQV = QV[[1]]
      uQV = QV[[2]]
      # Determines if a pair of covariates (xi, xj) is pure, mixed or neither
      # according to Kretowska 2017 and stores the results in a matrix
      poms = matrix("neither",N,N)
      for (i in 1:(N-1)) {
        xitime = data[i, self$time]
        xicensor = data[i, self$censor]
        for (j in (i+1):N) {
          xjtime = data[j, self$time]
          xjcensor = data[j, self$censor]
          if (
            (xicensor == 1) && (xjcensor == 1) && (abs(xitime - xjtime) < lQV)
          ) {
            poms[i, j] = "pure"
          } else if (
            ((xicensor == 1) && (xjcensor == 1) && (abs(xitime - xjtime) > uQV)) ||
            ((xicensor == 0) && (xjcensor == 1) && ((xitime - xjtime) > uQV)) ||
            ((xicensor == 1) && (xjcensor == 0) && ((xjtime - xitime) > uQV))
          ) {
            poms[i, j] = "mixed"
          }
        }
      }
      return(poms)
    },
    
    createtree = function(subset) {
      subX = self$traindata[subset, self$augmentedcovariates]
      subtree = Node$new("Node0", data = subX)
      self$createtreenode(subtree)
      subtree$Do(function(node) node$KMest <-self$KMcompute(node),
                 filterFun = isLeaf)
      subtree$Do(function(node) node$pureprop <-self$pureprop.compute(node))#,
      #           filterFun = isLeaf)
      return(subtree)
    },
    
    # CREATE QUADRATIC TREE RECURSIVELY
    createtreenode = function(node) {
      n = nrow(node$data)
      private$currentnodesize = n
      # Split only if node size is larger than threshold
      if (n > nsize) {
        # Instantiate book-keeping variables that are shared across many functions
        # These change at every iteration
        private$X = node$data
        private$Z = as.matrix(cbind(1, private$X))
        private$subsetX = strtoi(rownames(private$X))
        # Get the optimal splitting vector
        v = self$optimalv()
        node$optv <- v 
        lrnodes = self$lrnode.make(v)
        nl = nrow(lrnodes[[1]])
        nr = nrow(lrnodes[[2]])
        # Only grow the tree if both left and right nodes are nonempty
        if (nl > 0 && nr > 0) {
          splits <- lrnodes[[3]]
          lrstat <- self$lr.compute(splits)
          node$lrstat <- lrstat
          # label child nodes
          lcnodename = paste0(node$name,"l")
          rcnodename = paste0(node$name,"r")
          # grow the tree by adding child nodes to current node
          node$AddChild(lcnodename, data = lrnodes[[1]]) 
          node$AddChild(rcnodename, data = lrnodes[[2]])
          # recursively apply tree growing to each child
          self$createtreenode(node$children[[1]])
          self$createtreenode(node$children[[2]])
        }
      }
    },
    
    # GET OPTIMAL SPLITTING VECTOR OF CURRENT NODE DATA STORED IN private$X
    optimalv = function() {
      private$subpoms = self$poms[private$subsetX, private$subsetX]
      v = private$optimizer()
      return(v)
    },
    
    # USE VECTOR v TO SPLIT CURRENT private$X
    lrnode.make = function(v){
      splits = private$Z %*% v
      XL = private$X[splits < 0, ]
      XR = private$X[splits >= 0, ]
      return(list(XL, XR, splits))
    },
    
    # COMPUTE LOG RANK STATISTIC OF CURRENT private$X (WITH ITS SURVIVAL INFORMATION)
    lr.compute = function(splits){
      subdata = self$traindata[private$subsetX, ]
      Y = Surv(
        subdata[self$time][[1]], subdata[self$censor][[1]] == 1
      )
      lrstat = survdiff(Y ~ splits < 0)[[5]]
      return(lrstat)
    },
    
    
    # METHOD FOR ADDING KM ESTIMATES TO TERMINAL NODES 
    KMcompute = function(node) {
      X<-node$data 
      subsetX = strtoi(rownames(X))
      datasubset = self$traindata[subsetX,]
      Y<-Surv(datasubset[time][[1]],datasubset[censor][[1]]==1)
      kmfit=survfit(Y~1)
      return(kmfit) 
    },
    
    
    # PURE PROPORTION IN TERMINAL
    pureprop.compute = function(node) {
      subrows = strtoi(rownames(node$data))
      subpoms = self$poms[subrows, subrows]
      subtable = table(subpoms)
      pureprop = subtable["pure"]/(subtable["pure"] + subtable["mixed"])
      return(pureprop)
    },
    
    
    
    # ADD PRUNING CRITERIA NUMBERS
    pruningstat = function(node) {
      GTh<-sum(node$Get("lrstat",filterFun=isNotLeaf))
      Sh <- node$totalCount - node$leafCount
      gh <- GTh/Sh
    },
    
    
    
    # PREDICT TIME
    predicttime = function(testdata, trainedtree) {
      quadtestdata = self$augment.quadratic(testdata)
      testdataX = quadtestdata[self$augmentedcovariates]
      predictedtimes = rep(NA, nrow(testdataX))
      testdataZ = as.matrix(cbind(1, testdataX))
      for (i in 1:nrow(testdataZ)) {
        private$testz = testdataZ[i,]
        self$predrec(trainedtree)
        predictedtimes[i] = private$predtesttime
      }
      return(predictedtimes)
    },
    
    
    # RECURSIVELY TRAVERSE FOR PREDICTED TIME
    predrec = function(node) {
      if (isLeaf(node)) {
        km = node$KMest
        kmmed = summary(km)$table["median"][[1]]
        pred = if (is.na(kmmed)) {
          #summary(km)$table["*rmean"][[1]]
          mean(self$traindata[rownames(node$data),self$time])
        } else {
          kmmed
        }
        private$predtesttime = pred
      } else {
        split = sum(private$testz * node$optv)
        if (split < 0) {
          self$predrec(node$children[[1]])
        } else {
          self$predrec(node$children[[2]])
        }
      }
    },
    
    
    
    
    # CONCORDANCE INDEX
    cindex = function(actualtime, predictedtime, censor, testpoms) {
      N = length(actualtime)
      matches = 0
      legitcomparisons = 0
      for(i in 1:N) {
        for(j in 1:N) {
          if (testpoms[i, j] == "mixed") {
            actualless = (actualtime[i] < actualtime[j])
            predictedless = (predictedtime[i] < predictedtime[j])
            concorded = actualless && predictedless
            
            notsamenode = predictedtime[i] != predictedtime[j]
            
            matches = matches+censor[i]*as.numeric(
              concorded && notsamenode
            )
            
            legitcomparisons = legitcomparisons+censor[i]*as.numeric(
              actualless && notsamenode
            ) 
          }
        }
      }
      matches/legitcomparisons
    }
    
  ),
  
  
  
  private = list(
    
    # CONSTANT VARIABLE FOR INTERNAL USE ONLY
    v0.default.index = NULL,
    
    # SHARED BOOK-KEEPING VARIABLES FOR INTERNAL USE ONLY
    # THESE CHANGE FREQUENTLY AND UNPREDICTABLY
    Z = NULL,
    X = NULL,
    subsetX = NULL,
    subpoms = NULL,
    currentnodesize = NULL,
    
    testz = NULL,
    predtesttime = NULL,
    
    # INITIAL GUESS OF OPTIMAL VECTOR FOR OPTIMIZER
    v0.default = function() {
      v0 = rep(0, ncol(private$X) + 1)
      v0[1] = -mean(private$X[, private$v0.default.index])
      v0[3] = 1
      return(v0)
    },
    
    # THE DIPOLAR CRITERION FUNCTION
    criterion = function(v) {
      phipm.list <- private$phipmcount(v)
      Zv <- phipm.list[[1]]
      phipm = phipm.list[[2]]
      criterionvalue <- phipm %*% pmax(self$epsilon + c(-Zv, Zv), 0)
      return(
        list(criterionvalue, phipm)
      )
    },
    
    # COEFFICIENT CALCULATOR FOR THE DIPOLAR CRITERION FUNCTION
    phipmcount = function(v){
      
      #print(v)
      #print(private$Z)
      
      Zv <- private$Z %*% v
      N <- nrow(private$Z)
      phip <- rep(0, N)
      phim <- rep(0, N)
      for (i in 1:(N-1)) {
        for (j in (i+1):N) {
          if (private$subpoms[i, j] == "pure") {
            # if we EXPECT both zi and zj on +ve side of v:
            if (Zv[i] + Zv[j] > 0) {
              phip[i] = phip[i] + self$pureweight
              phip[j] = phip[j] + self$pureweight
              # otherwise:
            } else {
              phim[i] = phim[i] + self$pureweight
              phim[j] = phim[j] + self$pureweight
            }
          } else if (private$subpoms[i, j] == "mixed") {
            # if we EXPECT zi on +ve side of v
            # while zj on -ve side of v:
            if (Zv[i] - Zv[j] > 0) {
              phip[i] = phip[i] + self$mixedweight
              phim[j] = phim[j] + self$mixedweight
              # otherwise:
            } else {
              phim[i] = phim[i] + self$mixedweight
              phip[j] = phip[j] + self$mixedweight
            }
          }
        }
      }
      return(
        list(Zv, c(phip, phim))
      )
    },
    
    # OPTIMIZER TO FIND OPTIMAL SPLITTING VECTOR
    optimizer = function(v0) {
      v0 = private$v0.default()
      phipm.list <- private$phipmcount(v0)
      phipm = phipm.list[[2]]
      # Set up linear program
      N <- nrow(private$Z)
      Dp1 <- ncol(private$Z)
      
      Dlinp1 = length(self$covariates) + 1
      Dquad = Dp1 - Dlinp1
      quadconstmat = c(rep(0, Dlinp1), rep(-1, Dquad),
                       rep(0, Dlinp1), rep(-1, Dquad),
                       rep(0,2*N))
      #print(quadconstmat)
      # Coefficients of objective
      # NOTE: lp assumes ALL variables are >= 0.
      # This means the free variable v must be written as
      # v = v' - v'' : v', v'' >= 0
      # to get an lp in standard form
      objcoeffs <- c(rep(0, 2*Dp1), rep(1, 2*N))
      I2N <- diag(1, 2*N)
      pZmZ <- rbind(private$Z, -private$Z)
      phipm.pZmZ <- phipm * pZmZ
      # Constraint matrix
      # NOTE: lp assumes ALL variables are >= 0.
      # This means the free variable v must be written as
      # v = v' - v'' : v', v'' >= 0
      # to get an lp in standard form
      constmat <- cbind(phipm.pZmZ, -phipm.pZmZ, I2N)
      constmat <- rbind(constmat, quadconstmat)
      # Constraint RHS
      quadmaxsum.scalefactor = self$quadmaxsum.scalebysize(
        private$currentnodesize
      )
      quadmaxsum.scaled = self$quadmaxsum * quadmaxsum.scalefactor
      constrhs <- c(self$epsilon * phipm, -quadmaxsum.scaled)
      # NOTE: lp assumes ALL variables are >= 0
      lpsoln <- lp(direction = "min",
                   objective.in = objcoeffs,
                   const.mat = constmat,
                   const.dir = ">=",
                   const.rhs = constrhs)
      v1 <- lpsoln$solution[1 : Dp1] -  lpsoln$solution[(Dp1+1) : (2*Dp1)]
      # Reorientation phase
      vold = v1
      criterion.list.old = private$criterion(vold)
      i = 0
      repeat {
        phipm.old <- criterion.list.old[[2]]
        phipm.pZmZ.new <- phipm.old * pZmZ
        # Constraint matrix
        # NOTE: lp assumes ALL variables are >= 0.
        # This means the free variable v must be written as
        # v = v' - v'' : v', v'' >= 0
        # to get an lp in standard form
        constmat.new <- cbind(phipm.pZmZ.new, -phipm.pZmZ.new, I2N)
        constmat.new <- rbind(constmat.new, quadconstmat)
        # Constraint RHS
        constrhs.new <- c(self$epsilon * phipm.old, -quadmaxsum.scaled)
        lpsoln.new <- lp(direction = "min",
                         objective.in = objcoeffs,
                         const.mat = constmat.new,
                         const.dir = ">=",
                         const.rhs = constrhs.new)
        vnew <- lpsoln.new$solution[1 : Dp1] -  lpsoln.new$solution[(Dp1+1) : (2*Dp1)]
        criterion.list.new = private$criterion(vnew)
        vold = vnew
        i = i + 1
        if (abs(criterion.list.old[[1]] - criterion.list.new[[1]]) < self$tolerance) {
          break
        }
        criterion.list.old = criterion.list.new
      }
      return(vold)
    }
    
  )
  
)

