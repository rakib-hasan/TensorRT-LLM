#
# SPDX-FileCopyrightText: Copyright (c) 1993-2022 NVIDIA CORPORATION &
# AFFILIATES. All rights reserved. SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.
#

macro(setup_cuda_compiler)
  # Determine CUDA version before enabling the language extension
  # check_language(CUDA) clears CMAKE_CUDA_HOST_COMPILER if CMAKE_CUDA_COMPILER
  # is not set
  include(CheckLanguage)
  if(NOT CMAKE_CUDA_COMPILER AND CMAKE_CUDA_HOST_COMPILER)
    set(CMAKE_CUDA_HOST_COMPILER_BACKUP ${CMAKE_CUDA_HOST_COMPILER})
  endif()
  check_language(CUDA)
  if(CMAKE_CUDA_HOST_COMPILER_BACKUP)
    set(CMAKE_CUDA_HOST_COMPILER ${CMAKE_CUDA_HOST_COMPILER_BACKUP})
    check_language(CUDA)
  endif()
  if(CMAKE_CUDA_COMPILER)
    message(STATUS "CUDA compiler: ${CMAKE_CUDA_COMPILER}")
    if(NOT WIN32) # Linux
      execute_process(
        COMMAND
          "bash" "-c"
          "${CMAKE_CUDA_COMPILER} --version | egrep -o 'V[0-9]+.[0-9]+.[0-9]+' | cut -c2-"
        RESULT_VARIABLE _BASH_SUCCESS
        OUTPUT_VARIABLE CMAKE_CUDA_COMPILER_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE)

      if(NOT _BASH_SUCCESS EQUAL 0)
        message(FATAL_ERROR "Failed to determine CUDA version")
      endif()

    else() # Windows
      execute_process(
        COMMAND ${CMAKE_CUDA_COMPILER} --version
        OUTPUT_VARIABLE versionString
        RESULT_VARIABLE versionResult)

      if(versionResult EQUAL 0 AND versionString MATCHES
                                   "V[0-9]+\\.[0-9]+\\.[0-9]+")
        string(REGEX REPLACE "V" "" version ${CMAKE_MATCH_0})
        set(CMAKE_CUDA_COMPILER_VERSION "${version}")
      else()
        message(FATAL_ERROR "Failed to determine CUDA version")
      endif()
    endif()
  else()
    message(FATAL_ERROR "No CUDA compiler found")
  endif()

  set(CUDA_REQUIRED_VERSION "11.2")
  if(CMAKE_CUDA_COMPILER_VERSION VERSION_LESS CUDA_REQUIRED_VERSION)
    message(
      FATAL_ERROR
        "CUDA version ${CMAKE_CUDA_COMPILER_VERSION} must be at least ${CUDA_REQUIRED_VERSION}"
    )
  endif()
endmacro()

macro(setup_cuda_architectures)
  # cmake-format: off
    # Initialize and normalize CMAKE_CUDA_ARCHITECTURES before enabling CUDA.
    # Special values:
    # * `native` is resolved to HIGHEST available architecture.
    #   * Fallback to `all` if detection failed.
    # * `all`/unset is resolved to a set of architectures we optimized for and compiler supports.
    # * `all-major` is unsupported.
    # Numerical architectures:
    # * PTX is never included in result binary.
    #   * `*-virtual` architectures are therefore rejected.
    #   * `-real` suffix is automatically added to exclude PTX.
    # * Always use accelerated (`-a` suffix) target for supported architectures.
    # cmake-format: on

  if(CMAKE_CUDA_ARCHITECTURES STREQUAL "native")
    # Detect highest available compute capability
    set(OUTPUTFILE ${PROJECT_BINARY_DIR}/detect_cuda_arch)
    set(CUDAFILE ${CMAKE_SOURCE_DIR}/cmake/utils/detect_cuda_arch.cu)
    execute_process(COMMAND ${CMAKE_CUDA_COMPILER} -lcuda ${CUDAFILE} -o
                            ${OUTPUTFILE})
    message(VERBOSE "Detecting native CUDA compute capability")
    execute_process(
      COMMAND ${OUTPUTFILE}
      RESULT_VARIABLE CUDA_RETURN_CODE
      OUTPUT_VARIABLE CUDA_ARCH_OUTPUT)
    if(NOT ${CUDA_RETURN_CODE} EQUAL 0)
      message(WARNING "Detecting native CUDA compute capability - fail")
      message(
        WARNING
          "CUDA compute capability detection failed, compiling for all optimized architectures"
      )
      unset(CMAKE_CUDA_ARCHITECTURES)
    else()
      message(STATUS "Detecting native CUDA compute capability - done")
      set(CMAKE_CUDA_ARCHITECTURES "${CUDA_ARCH_OUTPUT}")
    endif()
  elseif(CMAKE_CUDA_ARCHITECTURES STREQUAL "all")
    unset(CMAKE_CUDA_ARCHITECTURES)
    message(
      STATUS
        "Setting CMAKE_CUDA_ARCHITECTURES to all enables all architectures TensorRT-LLM optimized for, "
        "not all architectures CUDA compiler supports.")
  elseif(CMAKE_CUDA_ARCHITECTURES STREQUAL "all-major")
    message(
      FATAL_ERROR
        "Setting CMAKE_CUDA_ARCHITECTURES to all-major does not make sense for TensorRT-LLM. "
        "Please enable all architectures you intend to run on, so we can enable optimized kernels for them."
    )
  else()
    unset(CMAKE_CUDA_ARCHITECTURES_CLEAN)
    foreach(CUDA_ARCH IN LISTS CMAKE_CUDA_ARCHITECTURES)
      if(CUDA_ARCH MATCHES "^([1-9])([0-9])+a?-virtual$")
        message(FATAL_ERROR "Including PTX in compiled binary is unsupported.")
      elseif(CUDA_ARCH MATCHES "^(([1-9])([0-9])+)a?(-real)?$")
        list(APPEND CMAKE_CUDA_ARCHITECTURES_CLEAN ${CMAKE_MATCH_1})
      else()
        message(FATAL_ERROR "Unrecognized CUDA architecture: ${CUDA_ARCH}")
      endif()
    endforeach()
    list(REMOVE_DUPLICATES CMAKE_CUDA_ARCHITECTURES_CLEAN)
    set(CMAKE_CUDA_ARCHITECTURES ${CMAKE_CUDA_ARCHITECTURES_CLEAN})
  endif()

  if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES "80" "86")
    if(CMAKE_CUDA_COMPILER_VERSION VERSION_GREATER_EQUAL "11.8")
      list(APPEND CMAKE_CUDA_ARCHITECTURES "89" "90")
    endif()
    if(CMAKE_CUDA_COMPILER_VERSION VERSION_GREATER_EQUAL "12.7")
      list(APPEND CMAKE_CUDA_ARCHITECTURES "100" "120")
    endif()
  endif()

  # CMAKE_CUDA_ARCHITECTURES_ORIG contains all architectures enabled, without
  # automatically added -real or -a suffix.
  set(CMAKE_CUDA_ARCHITECTURES_ORIG "${CMAKE_CUDA_ARCHITECTURES}")
  message(STATUS "GPU architectures: ${CMAKE_CUDA_ARCHITECTURES_ORIG}")

  set(ARCHITECTURES_WITH_KERNELS "80" "86" "89" "90" "100" "120")
  foreach(CUDA_ARCH IN LISTS ARCHITECTURES_WITH_KERNELS)
    if(NOT "${CUDA_ARCH}" IN_LIST CMAKE_CUDA_ARCHITECTURES_ORIG)
      add_definitions("-DEXCLUDE_SM_${CUDA_ARCH}")
      message(STATUS "Excluding SM ${CUDA_ARCH}")
    endif()
  endforeach()

  set(ARCHITECTURES_WITH_ACCEL "90" "100" "101" "120")
  unset(CMAKE_CUDA_ARCHITECTURES_NORMALIZED)
  foreach(CUDA_ARCH IN LISTS CMAKE_CUDA_ARCHITECTURES)
    if("${CUDA_ARCH}" IN_LIST ARCHITECTURES_WITH_ACCEL)
      list(APPEND CMAKE_CUDA_ARCHITECTURES_NORMALIZED "${CUDA_ARCH}a-real")
    else()
      list(APPEND CMAKE_CUDA_ARCHITECTURES_NORMALIZED "${CUDA_ARCH}-real")
    endif()
  endforeach()
  set(CMAKE_CUDA_ARCHITECTURES ${CMAKE_CUDA_ARCHITECTURES_NORMALIZED})
endmacro()
