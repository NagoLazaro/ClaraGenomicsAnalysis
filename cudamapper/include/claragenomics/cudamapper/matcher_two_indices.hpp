/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#pragma once

#include <memory>
#include <thrust/device_vector.h>
#include <claragenomics/cudamapper/index_two_indices.hpp>

namespace claragenomics
{

namespace cudamapper
{
/// \addtogroup cudamapper
/// \{

/// MatcherTwoIndices - base matcher
class MatcherTwoIndices
{
public:
    /// \brief Virtual destructor
    virtual ~MatcherTwoIndices() = default;

    /// \brief returns anchors
    /// \return anchors
    virtual thrust::device_vector<Anchor>& anchors() = 0;

    /// \brief Creates a Matcher object
    /// \param query_index
    /// \param target_index
    /// \return matcher
    static std::unique_ptr<MatcherTwoIndices> create_matcher(const IndexTwoIndices& query_index,
                                                             const IndexTwoIndices& target_index);
};

/// \}

} // namespace cudamapper

} // namespace claragenomics