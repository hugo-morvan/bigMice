#' MICE for Spark DataFrames using Sparklyr and Spark MLlib
#'
#' This function imputes missing values in a Spark DataFrame using MICE (Multiple Imputation by Chained Equations) algorithm.
#'
#' @importFrom dplyr %>%
#'
#'
#' @param sc A Spark connection
#' @param data A Spark DataFrame
#' @param variable_types A named character vector, the variable types of the columns in the data.
#' @param analysis_formula A formula, the formula to use for the analysis
#' @param m The number of imputations to perform
#' @param method A character vector, the imputation method to use for each variable. If NULL, the function will infer the method based on the variable types.
#' @param predictorMatrix A matrix, the predictor matrix to use for the imputation. TBD
#' @param formulas A list, the formulas to use for the imputation. If NULL, the function will infer the formulas based on the other variables present in the data. TBD
#' @param modeltype A character vector, the model type to use for the imputation. If NULL, the function will infer the model type based on the variable types. TBD
#' @param maxit The maximum number of iterations to perform
#' @param printFlag A boolean, whether to print debug information
#' @param seed An integer, the seed to use for reproducibility
#' @param imp_init A Spark DataFrame, the original data with missing values, but with initial imputation (by random sampling or mean/median/mode imputation). Can be set to avoid re-running the initialisation step. Otherwise, the function will perform the initialisation step using the MeMoMe function.
#' @param ... Additional arguments to be passed to the function. TBD
#' @return A list containing the Rubin's statistics for the model parameters, the per-imputation statistics, the imputation statistics, and the model parameters.
#' @export
#' @examples
#' #TBD

mice.spark <- function(data,
                       sc,
                       variable_types, # Used for initialization and method selection
                       analysis_formula,
                       m = 5,
                       method = NULL,
                       predictorMatrix = NULL,
                       formulas = NULL,
                       modeltype = NULL,
                       maxit = 5,
                       printFlag = TRUE,
                       seed = NA,
                       imp_init = NULL,
                       ...) {

  cat("\nUsing bigMICE version 0.1.5 \n")
  if (!is.na(seed)) set.seed(seed)

  # check form of data and m
  #data <- check.spark.dataform(data)

  #m <- check.m(m)

  from <- 1
  to <- from + maxit - 1

  # INITIALISE THE IMPUTATION USING Mean/Mode/Median SAMPLING
  cols <- names(variable_types)
  # Do this inside or outside the m loop ?
  # Do I want each imputation to start from the same sample or have more variation in initial condition ?

  #TODO : add support for column parameter in initialisation

  # Dictionnary to infer initialization method based on variable type
  # Should be one of (mean, mode, median, none), and be used as input of MeMoMe function
  # init_dict <- c("Binary" = "mode",
  #                "Nominal" = "mode",
  #                "Ordinal" = "mode",
  #                "Code (don't impute)" = "none", # LopNr, Unit_code etc...
  #                "Continuous_int" = "median",
  #                "Continuous_float" = "mean",
  #                "smalldatetime" = "none",
  #                "String" = "none", #TBD
  #                "Count" = "median", #TBD
  #                "Semi-continuous" = "none", #TBD
  #                "Else", "none")
  #
  # init_modes <- replace(variable_types, variable_types %in% names(init_dict), init_dict[variable_types])
  # names(init_modes) <- cols
  # # print("**DEBUG**: init_modes:")
  # # print(init_modes)
  #
  # cat("\nStarting initialisation\n")
  # # print(" ")
  #
  # # print(length(init_modes))
  # # print(sdf_ncol(data))
  # #
  # init_start_time <- proc.time()
  # if(is.null(imp_init)){
  #   imp_init <- impute_with_MeMoMe(sc = sc,
  #                                  sdf = data,
  #                                  column = NULL, #TODO: add support for this
  #                                  impute_mode = init_modes)
  # }else{
  #   print("Using initial imputation provided manually, I hope it is correct")
  #   imp_init <- imp_init # User provided initiale imputation
  # }
  #
  # init_end_time <- proc.time()
  # init_elapsed <- (init_end_time-init_start_time)['elapsed']
  # cat("\nInitalisation time:", init_elapsed)
  # TODO : Add elapse time to the result dataframe (and create result dataframe)

  ### Rubin Rules Stats INIT###
  # Get the formula for the model
  formula_obj <- analysis_formula
  param_names <- c("(Intercept)", all.vars(formula_obj)[-1])

  model_params <- vector("list", m)

  # List to store per-imputation information
  imputation_stats <- vector("list", m)



  # FOR EACH IMPUTATION SET i = 1, ..., m
  for (i in 1:m) {
    cat("\nStarting initialisation\n")

    init_start_time <- proc.time()

    imp_init <- init_with_random_samples(sc, data, column = NULL)
    imp_init <- imp_init %>% select(-all_of("temp_row_id"))
    # Check that the initialised data does not contain any missing values
    init_end_time <- proc.time()
    init_elapsed <- (init_end_time-init_start_time)['elapsed']
    cat("Initalisation time:", init_elapsed)

    cat("\nImputation: ", i, "\n")

    # Run the imputation algorithm
    cat("Starting imputation")

    imp_start_time <- proc.time()

    imp <- sampler.spark(sc = sc,
                         data = data,
                         imp_init = imp_init,
                         fromto = c(from, to),
                         var_types = variable_types,
                         predictorMatrix = predictorMatrix,
                         printFlag = printFlag)

    imp_end_time <- proc.time()
    imp_elapsed <- (imp_end_time-imp_start_time)['elapsed']
    cat("\nImputation time:", imp_elapsed,".\n")

    # Save imputation to dataframe ? Maybe only the last one ?

    # Compute user-provided analysis on the fly on the imputed data ?

    # Calculate Rubin Rules statistics
    # Fit model on imputed data
    cat("Fitting model on imputed data\n")
    #print(colnames(imp))

    # Clearing the extra columns created by the imputer (Bug, needs to be fixed)
    # Need to look at each imputer to see which one returns the extra cols
    # Or does the model created also create new cols in the data ?
    pre_pred_cols <- c(colnames(data))
    print(pre_pred_cols)
    post_pred_cols <- colnames(imp)
    print(post_pred_cols)
    extra_cols <- setdiff(post_pred_cols, pre_pred_cols)

    imp <- imp %>% dplyr::select(-dplyr::all_of(extra_cols))
    print(colnames(imp))
    model <- imp %>%
      sparklyr::ml_logistic_regression(formula = formula_obj)

    print(model)
    # Store model coefficients
    model_params[[i]] <- model$coefficients
    print(model$coefficients)
    # Create per-imputation summary for this iteration
    imp_summary <- list(
      imputation_number = i,
      imputation_time = imp_elapsed
    )

    # Add model coefficients to the imputation summary
    for (param in param_names) {
      if (param %in% names(model$coefficients)) {
        imp_summary[[param]] <- model$coefficients[[param]]
      } else {
        # Handle case where parameter might not be in the model
        imp_summary[[param]] <- NA
      }
    }

    # Save this imputation's stats
    imputation_stats[[i]] <- imp_summary

  } # END FOR EACH IMPUTATION SET i = 1, ..., m

  # Rubin's Statistics for model parameters
  results <- list()

  # Create a matrix of parameters from all imputations
  params_matrix <- do.call(rbind, model_params)

  for (param in param_names) {
    if (param %in% colnames(params_matrix)) {
      param_values <- params_matrix[, param]

      # Calculate Rubin's statistics
      pooled_param <- mean(param_values, na.rm = TRUE)
      between_var <- sum((param_values - pooled_param)^2) / (m - 1)

      # For model parameters, within variance needs to be estimated from model
      # Here we'll use a simplified approach - using the variance of the estimates
      # In a more complete implementation, this would come from the model's variance-covariance matrix
      within_var <- mean((param_values - pooled_param)^2) / m

      total_var <- within_var + between_var + (between_var / m)

      results[[param]] <- list(
        pooled_param = pooled_param,
        within_var = within_var,
        between_var = between_var,
        total_var = total_var,
        values = param_values
      )
    }
  }

  # data frame for per-imputation statistics
  per_imputation_df <- do.call(rbind, lapply(imputation_stats, function(imp) {
    data.frame(imp, stringsAsFactors = FALSE)
  }))

  # Returning both the aggregated results and per-imputation statistics
  return(list(
    rubin_stats = results,
    per_imputation = per_imputation_df,
    imputation_stats = imputation_stats,
    model_params = model_params
  ))
}


#' MICE sampler function
#'
#' This function is the core of the MICE algorithm. It iteratively imputes missing values in a Spark DataFrame using a set of imputation methods based on the variable types.
#'
#' @param sc A Spark connection
#' @param data A Spark DataFrame, the original data with missing values
#' @param imp_init A Spark DataFrame, the original data with missing values, but with initial imputation (by random sampling or mean/median/mode imputation)
#' @param fromto A vector of length 2, the range of iterations to perform (from, to)
#' @param var_types A named character vector, the variable types of the columns in the data.
#' @param printFlag A boolean, whether to print debug information.
#' @param predictorMatrix A matrix, the predictor matrix to use for the imputation. TBD
#' @return The Spark DataFrame with missing values imputed for all variables
#' @export
#' @examples
#' #TBD
sampler.spark <- function(sc,
                          data,
                          imp_init,
                          fromto,
                          var_types,
                          predictorMatrix = NULL,
                          printFlag){


  #TODO; add support for functionalities present in the mice() function (where, ignore, blocks, predictorMatrix, formula, ...)

  # For iteration k in fromto
  from = fromto[1]
  to = fromto[2]

  var_names <- names(sparklyr::sdf_schema(data))

  # Method dictionary for imputation. Can change as desired
  # TODO: implement; keep this as default, or use user-provided dict ?
  method_dict <- c("Binary" = "Logistic",
                   "Nominal" = "Mult_Logistic",
                   "Ordinal" = "RandomForestClassifier",
                   "Code (don't impute)" = "none", # LopNr, Unit_code etc...
                   "Continuous_int" = "Linear",
                   "Continuous_float" = "Linear",
                   "smalldatetime" = "none",  #TBD
                   "String" = "none", #TBD
                   "Count" = "RandomForestClassifier", #TBD
                   "Semi-continuous" = "none", #TBD
                   "Else" = "none")

  imp_methods <- replace(var_types, var_types %in% names(method_dict), method_dict[var_types])
  names(imp_methods) <- var_names
  # print(imp_methods)
  num_vars <- length(var_names)
  # print("**DEBUG**: imp_methods:")
  # initialize the result with the initial imputation (mean or random)
  result <- imp_init

  for (k in from:to){
    cat("\n iteration: ", k)

    # For each variable j in the data
    j <- 0
    for (var_j in var_names){
      j <- j + 1
      cat("\n",j,"/",num_vars,"Imputing variable", var_j,"using method ")

      method <- imp_methods[[var_j]]
      cat(method,"\n")

      # Obtain the variables use to predict the missing values of variable j and create feature column
      label_col <- var_j # string object

      # DEFAULT: all other variables
      feature_cols <- setdiff(var_names, label_col)
      # remove the features with "none" imputation method (lpopNr, Unit_code, etc... )
      feature_cols <- feature_cols[which(imp_methods[feature_cols] != "none")]

      # NON-DEFAULT: If predictorMatrix is provided, use it to select the features
      if(!is.null(predictorMatrix)){

        #Fetch the user-defined predictors for the label var_j
        UD_predictors <- colnames(predictorMatrix)[predictorMatrix[label_col, ]]

        #Check if the predictors are in the data
        if(length(UD_predictors) > 0){
          #If they are, use them as features
          feature_cols <- intersect(feature_cols, UD_predictors)


        }else{
          #If not, use stop
          cat(paste("The user-defined predictors for variable", label_col, "are not in the data or no predictors left after using user-defined predictors. Skipping Imputation for this variable.\n"))
          next
        }
      }else{
        #If not, use the default predictors
      }

      # Filter out Date data type (unsupported) (redundant?)
      feature_cols <- feature_cols[sapply(var_types[feature_cols],
                                          function(x) !(x %in% c("String", "smalldatetime")))]

      # Replace present values in label column with the original missing values
      # Is this done innefficiently (cbind)? Need to look into more optimized method maybe (spark native)
      j_df <- result %>%
        sparklyr::select(-label_col) %>%
        cbind(data %>% sparklyr::select(dplyr::all_of(label_col)))
      #cat("colnames j-df", colnames(j_df))
      # To calculate the residuals (linear method only for now), we need to keep the previous values in label_col
      #print("1")
      label_col_prev <- result %>% sparklyr::select(label_col)
      print("DEBUG: label_col_prev")
      print(label_col_prev)
      # Could this be avoided by passing in result to the impute function ? less select actions ?
      #print("2")
      result <- switch(method,
         "Logistic" = impute_with_logistic_regression(sc, j_df, label_col, feature_cols),
         "Mult_Logistic" = impute_with_mult_logistic_regression(sc, j_df, label_col, feature_cols),
         "Linear" = impute_with_linear_regression(sc=sc, sdf=j_df, target_col=label_col,
                                        feature_cols=feature_cols, target_col_prev=label_col_prev),
         "RandomForestClassifier" = impute_with_random_forest_classifier(sc, j_df, label_col, feature_cols),
         "RandomForestRegressor" = impute_with_random_forest_regressor(sc, sdf=j_df, target_col=label_col,
                                        feature_cols=feature_cols, target_col_prev=label_col_prev),
         "none" = j_df, # don't impute this variable
         "Invalid method"  # Default case, should never be reached
      ) # end of switch block
      print("DEBUG: post switch")
    } # end of var_j loop (each variable) (1 iteration)

    # Checkpoint here ?
    print("checkpointing...")
    result <- sparklyr::sdf_checkpoint(result)

  } # end of k loop (iterations)

  return(result)
} # end of sampler.spark function

#' MICE+ for Spark DataFrames using Sparklyr and Spark MLlib
#'
#' This function imputes missing values in a Spark DataFrame using MICE (Multiple Imputation by Chained Equations) algorithm. Additionally, it allows to look at the imputed values to see if they are reasonable and measure the uncertainty of the imputation.
#'
#' @importFrom dplyr %>%
#' @importFrom Matrix Matrix
#'
#' @param sc A Spark connection
#' @param data A Spark DataFrame, the original data with extra missing values
#' @param data_true A Spark DataFrame, the original data without extra missing values
#' @param variable_types A named character vector, the variable types of the columns in the data.
#' @param analysis_formula A formula, the formula to use for the analysis
#' @param where_missing A logical vector, the locations of the missing values in the data
#' @param m The number of imputations to perform
#' @param method A character vector, the imputation method to use for each variable. If NULL, the function will infer the method based on the variable types.
#' @param predictorMatrix A matrix, the predictor matrix to use for the imputation. TBD
#' @param formulas A list, the formulas to use for the imputation. If NULL, the function will infer the formulas based on the other variables present in the data. TBD
#' @param modeltype A character vector, the model type to use for the imputation. If NULL, the function will infer the model type based on the variable types. TBD
#' @param maxit The maximum number of iterations to perform
#' @param printFlag A boolean, whether to print debug information
#' @param seed An integer, the seed to use for reproducibility
#' @param imp_init A Spark DataFrame, the original data with missing values, but with initial imputation (by random sampling or mean/median/mode imputation). Can be set to avoid re-running the initialisation step. Otherwise, the function will perform the initialisation step using the MeMoMe function.
#' @param ... Additional arguments to be passed to the function. TBD
#' @return A list containing the Rubin's statistics for the model parameters, the per-imputation statistics, the imputation statistics, and the model parameters.
#' @export
#' @examples
#' #TBD

mice.spark.plus <- function(data, #data + 10% missing
                       data_true, #data without missing
                       sc,
                       variable_types, # Used for initialization and method selection
                       analysis_formula,
                       where_missing,
                       m = 5,
                       method = NULL,
                       predictorMatrix = NULL,
                       formulas = NULL,
                       modeltype = NULL,
                       maxit = 5,
                       printFlag = TRUE,
                       seed = NA,
                       imp_init = NULL,
                       ...) {

  cat("\nUsing bigMICE version 0.1.6 \n")
  if (!is.na(seed)) set.seed(seed)

  # check form of data and m
  #data <- check.spark.dataform(data)

  #m <- check.m(m)

  from <- 1
  to <- from + maxit - 1

  # INITIALISE THE IMPUTATION USING Mean/Mode/Median SAMPLING
  cols <- names(variable_types)
  # Do this inside or outside the m loop ?
  # Do I want each imputation to start from the same sample or have more variation in initial condition ?

  #TODO : add support for column parameter in initialisation

  # Dictionnary to infer initialization method based on variable type
  # Should be one of (mean, mode, median, none), and be used as input of MeMoMe function
  init_dict <- c("Binary" = "mode",
                 "Nominal" = "mode",
                 "Ordinal" = "mode",
                 "Code (don't impute)" = "none", # LopNr, Unit_code etc...
                 "Continuous_int" = "median",
                 "Continuous_float" = "mean",
                 "smalldatetime" = "none",
                 "String" = "none", #TBD
                 "Count" = "median", #TBD
                 "Semi-continuous" = "none", #TBD
                 "Else", "none")

  init_modes <- replace(variable_types, variable_types %in% names(init_dict), init_dict[variable_types])
  names(init_modes) <- cols
  # print("**DEBUG**: init_modes:")
  # print(init_modes)


  # TODO : Add elapse time to the result dataframe (and create result dataframe)

  ### Rubin Rules Stats INIT###
  # Get the formula for the model
  formula_obj <- analysis_formula
  param_names <- c("(Intercept)", all.vars(formula_obj)[-1])

  model_params <- vector("list", m)

  # List to store per-imputation information
  imputation_stats <- vector("list", m)

  # Object to store the known missing sparse matrices
  known_missings <- list()

  # FOR EACH IMPUTATION SET i = 1, ..., m
  for (i in 1:m) {
    cat("\nStarting initialisation\n")

    init_start_time <- proc.time()

    imp_init <- init_with_random_samples(sc, data, column = NULL)
    imp_init <- imp_init %>% select(-all_of("temp_row_id"))
    # Check that the initialised data does not contain any missing values
    init_end_time <- proc.time()
    init_elapsed <- (init_end_time-init_start_time)['elapsed']
    cat("Initalisation time:", init_elapsed)

    cat("\nImputation: ", i, "\n")

    # Run the imputation algorithm
    cat("Starting imputation")

    imp_start_time <- proc.time()

    imp <- sampler.spark(sc = sc,
                         data = data,
                         imp_init = imp_init,
                         fromto = c(from, to),
                         var_types = variable_types,
                         predictorMatrix = predictorMatrix,
                         printFlag = printFlag)

    imp_end_time <- proc.time()
    imp_elapsed <- (imp_end_time-imp_start_time)['elapsed']
    cat("\nImputation time:", imp_elapsed,".\n")

    # Save imputation to dataframe ? Maybe only the last one ?

    # Compute user-provided analysis on the fly on the imputed data ?

    # Calculate Rubin Rules statistics
    # Fit model on imputed data
    cat("Fitting model on imputed data\n")
    #print(colnames(imp))
    # Clearing the extra columns created by the imputer (Bug, needs to be fixed)
    # Need to look at each imputer to see which one returns the extra cols
    # Or does the model created also create new cols in the data ?
    pre_pred_cols <- c(colnames(data))
    post_pred_cols <- colnames(imp)
    extra_cols <- setdiff(post_pred_cols, pre_pred_cols)
    imp <- imp %>% dplyr::select(-dplyr::all_of(extra_cols))
    #print(colnames(imp))

    # Obtain known missings sparse matrix
    cat("Obtaining known missings sparse matrix.\n")

    # Collect the imo result:

    #print(known_missings_m)

    # Sparse location = is.na(data) & !is.na(data_true)
    # where_sparse <- data %>% sparklyr::select( dplyr::all_of(colnames(data))) %>%
    #   sparklyr::mutate(known = is.na(data) & !is.na(data_true)) %>%
    #   sparklyr::select(dplyr::all_of(colnames(data)), known)
    #
    # print("where_sparse")
    # print(where_sparse)


    # Extract the known missing from imp using where_sparse
    # known_missings_m <- imp %>%
    #   sparklyr::inner_join(where_sparse, by = colnames(data)) %>%
    #   sparklyr::select(dplyr::all_of(colnames(data)), known) %>%
    #   dplyr::filter(known == TRUE) %>%
    #   dplyr::select(-known)

    #print(known_missings_m)

    known_missings[[i]] <- imp

    #%%%% Analysis on the imputed data%%%%%
    model <- imp %>%
      sparklyr::ml_logistic_regression(formula = formula_obj)

    # Store model coefficients
    model_params[[i]] <- model$coefficients
    print(model$coefficients)
    # Create per-imputation summary for this iteration
    imp_summary <- list(
      imputation_number = i,
      imputation_time = imp_elapsed
    )

    # Add model coefficients to the imputation summary
    for (param in param_names) {
      if (param %in% names(model$coefficients)) {
        imp_summary[[param]] <- model$coefficients[[param]]
      } else {
        # Handle case where parameter might not be in the model
        imp_summary[[param]] <- NA
      }
    }

    # Save this imputation's stats
    imputation_stats[[i]] <- imp_summary

  } # END FOR EACH IMPUTATION SET i = 1, ..., m

  # Rubin's Statistics for model parameters
  results <- list()

  # Create a matrix of parameters from all imputations
  params_matrix <- do.call(rbind, model_params)

  for (param in param_names) {
    if (param %in% colnames(params_matrix)) {
      param_values <- params_matrix[, param]

      # Calculate Rubin's statistics
      pooled_param <- mean(param_values, na.rm = TRUE)
      between_var <- sum((param_values - pooled_param)^2) / (m - 1)

      # For model parameters, within variance needs to be estimated from model
      # Here we'll use a simplified approach - using the variance of the estimates
      # In a more complete implementation, this would come from the model's variance-covariance matrix
      within_var <- mean((param_values - pooled_param)^2) / m

      total_var <- within_var + between_var + (between_var / m)

      results[[param]] <- list(
        pooled_param = pooled_param,
        within_var = within_var,
        between_var = between_var,
        total_var = total_var,
        values = param_values
      )
    }
  }

  # data frame for per-imputation statistics
  per_imputation_df <- do.call(rbind, lapply(imputation_stats, function(imp) {
    data.frame(imp, stringsAsFactors = FALSE)
  }))

  # Returning both the aggregated results and per-imputation statistics
  return(list(
    rubin_stats = results,
    per_imputation = per_imputation_df,
    imputation_stats = imputation_stats,
    model_params = model_params,
    known_missings = known_missings
  ))
}

