/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include <chrono>
#include <getopt.h>
#include <iostream>
#include <string>
#include <deque>
#include <mutex>
#include <future>
#include <thread>
#include <atomic>

#include <claragenomics/logging/logging.hpp>
#include <claragenomics/io/fasta_parser.hpp>
#include <claragenomics/utils/cudautils.hpp>
#include <claragenomics/utils/ThreadPool.h>

#include <claragenomics/cudamapper/index.hpp>
#include <claragenomics/cudamapper/matcher.hpp>
#include <claragenomics/cudamapper/overlapper.hpp>
#include "overlapper_triggered.hpp"

static struct option options[] = {
    {"window-size", required_argument, 0, 'w'},
    {"kmer-size", required_argument, 0, 'k'},
    {"index-size", required_argument, 0, 'i'},
    {"target-index-size", required_argument, 0, 't'},
    {"help", no_argument, 0, 'h'},
};

void help(int32_t exit_code);

int main(int argc, char* argv[])
{
    claragenomics::logging::Init();

    uint32_t k               = 15;
    uint32_t w               = 15;
    size_t index_size        = 10000;
    size_t num_threads       = 1;
    size_t num_devices       = 1;
    size_t target_index_size = 10000;
    std::string optstring    = "t:i:k:w:h:r:d:";
    uint32_t argument;
    while ((argument = getopt_long(argc, argv, optstring.c_str(), options, nullptr)) != -1)
    {
        switch (argument)
        {
        case 'k':
            k = atoi(optarg);
            break;
        case 'w':
            w = atoi(optarg);
            break;
        case 'i':
            index_size = atoi(optarg);
            break;
        case 'r':
            num_threads = atoi(optarg);
            break;
        case 'd':
            num_devices = atoi(optarg);
            break;
        case 't':
            target_index_size = atoi(optarg);
            break;
        case 'h':
            help(0);
        default:
            exit(1);
        }
    }

    if (k > claragenomics::cudamapper::Index::maximum_kmer_size())
    {
        std::cerr << "kmer of size " << k << " is not allowed, maximum k = " << claragenomics::cudamapper::Index::maximum_kmer_size() << std::endl;
        exit(1);
    }

    // Check remaining argument count.
    if ((argc - optind) < 2)
    {
        std::cerr << "Invalid inputs. Please refer to the help function." << std::endl;
        help(1);
    }

    std::string query_filepath  = std::string(argv[optind++]);
    std::string target_filepath = std::string(argv[optind++]);

    bool all_to_all = false;
    if (query_filepath == target_filepath)
    {
        all_to_all        = true;
        target_index_size = index_size;
        std::cerr << "NOTE - Since query and target files are same, activating all_to_all mode. Query index size used for both files." << std::endl;
    }

    std::unique_ptr<claragenomics::io::FastaParser> query_parser = claragenomics::io::create_fasta_parser(query_filepath);
    int32_t queries                                              = query_parser->get_num_seqences();

    std::unique_ptr<claragenomics::io::FastaParser> target_parser = claragenomics::io::create_fasta_parser(target_filepath);
    int32_t targets                                               = target_parser->get_num_seqences();

    std::cerr << "Query " << query_filepath << " index " << queries << std::endl;
    std::cerr << "Target " << target_filepath << " index " << targets << std::endl;

    // Data structure for holding overlaps to be written out
    std::mutex overlaps_writer_mtx;

    // Function for adding new overlaps to writer
    auto filter_and_print_overlaps = [&overlaps_writer_mtx](claragenomics::cudamapper::Overlapper& overlapper,
                                                            thrust::device_vector<claragenomics::cudamapper::Anchor>& anchors,
                                                            const claragenomics::cudamapper::Index& index_query,
                                                            const claragenomics::cudamapper::Index& index_target) {
        CGA_NVTX_RANGE(profiler, "print out overlaps");

        std::vector<claragenomics::cudamapper::Overlap> overlaps_to_add;
        overlapper.get_overlaps(overlaps_to_add, anchors, index_query, index_target);

        std::vector<claragenomics::cudamapper::Overlap> filtered_overlaps;
        claragenomics::cudamapper::Overlapper::filter_overlaps(filtered_overlaps, overlaps_to_add);

        overlaps_writer_mtx.lock();
        claragenomics::cudamapper::Overlapper::print_paf(filtered_overlaps);
        overlaps_writer_mtx.unlock();

    };

    // Track overall time
    std::chrono::milliseconds index_time      = std::chrono::duration_values<std::chrono::milliseconds>::zero();
    std::chrono::milliseconds matcher_time    = std::chrono::duration_values<std::chrono::milliseconds>::zero();
    std::chrono::milliseconds overlapper_time = std::chrono::duration_values<std::chrono::milliseconds>::zero();


    struct query_target_range {
        std::pair<std::int32_t, int32_t> query_range;
        std::vector<std::pair<std::int32_t, int32_t>> target_ranges;
    };

    //First generate all the ranges independently, then loop over them.
    std::vector<query_target_range> query_target_ranges;

    for (std::int32_t query_start_index = 0; query_start_index < queries; query_start_index += index_size) {


        std::int32_t query_end_index = std::min(query_start_index + index_size, static_cast<size_t>(queries));

        query_target_range q;
        q.query_range = std::make_pair(query_start_index, query_end_index);

        std::int32_t target_start_index = 0;
        // If all_to_all mode, then we can optimzie by starting the target sequences from the same index as
        // query because all indices before the current query index are guaranteed to have been processed in
        // a2a mapping.
        if (all_to_all) {
            target_start_index = query_start_index;
        }

        for (; target_start_index < targets; target_start_index += target_index_size) {
            std::int32_t target_end_index = std::min(target_start_index + target_index_size,
                                                     static_cast<size_t>(targets));
            q.target_ranges.push_back(std::make_pair(target_start_index, target_end_index));
         }

        query_target_ranges.push_back(q);
    }

    auto compute_overlaps = [&](query_target_range query_target_range, int device_id){
        cudaSetDevice(device_id);

        auto query_start_index = query_target_range.query_range.first;
        auto query_end_index = query_target_range.query_range.second;

        std::cerr << "THREAD LAUNCHED: Query range: (" << query_start_index << " - " << query_end_index - 1 << ")" << std::endl;

        std::unique_ptr<claragenomics::cudamapper::Index> query_index(nullptr);
        std::unique_ptr<claragenomics::cudamapper::Index> target_index(nullptr);
        std::unique_ptr<claragenomics::cudamapper::Matcher> matcher(nullptr);

        {
            CGA_NVTX_RANGE(profiler, "generate_query_index");
            auto start_time = std::chrono::high_resolution_clock::now();
            query_index     = claragenomics::cudamapper::Index::create_index(*query_parser,
                                                                             query_start_index,
                                                                             query_end_index,
                                                                             k,
                                                                             w);
            index_time += std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::high_resolution_clock::now() - start_time);
        }

        //Main loop
        for (auto target_range: query_target_range.target_ranges) {

            auto target_start_index = target_range.first;
            auto target_end_index = target_range.second;

            {
                CGA_NVTX_RANGE(profiler, "generate_target_index");
                auto start_time = std::chrono::high_resolution_clock::now();
                target_index    = claragenomics::cudamapper::Index::create_index(*target_parser,
                                                                                 target_start_index,
                                                                                 target_end_index,
                                                                                 k,
                                                                                 w);
                index_time += std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::high_resolution_clock::now() - start_time);
            }
            {
                CGA_NVTX_RANGE(profiler, "generate_matcher");
                auto start_time = std::chrono::high_resolution_clock::now();
                matcher         = claragenomics::cudamapper::Matcher::create_matcher(*query_index,
                                                                                     *target_index);
                matcher_time += std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::high_resolution_clock::now() - start_time);
            }
            {

                claragenomics::cudamapper::OverlapperTriggered overlapper;
                CGA_NVTX_RANGE(profiler, "generate_overlaps");
                auto start_time = std::chrono::high_resolution_clock::now();
                filter_and_print_overlaps(overlapper, matcher->anchors(), *query_index, *target_index);
                overlapper_time += std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::high_resolution_clock::now() - start_time);

            }

        }
    };

    // create thread pool
    ThreadPool pool(num_threads);

    // Enqueue all the work in a thread pool
    std::vector<std::future<void>> futures;
    for (int i=0;i<query_target_ranges.size();i++){
        // enqueue and store future
        auto query_target_range = query_target_ranges[i];
        auto device_id = i % num_devices;
        futures.push_back(pool.enqueue(compute_overlaps, query_target_range, device_id));
    }

    for (auto &f: futures){
        f.wait();
    }

    std::cerr << "\n\n"
              << std::endl;
    std::cerr << "Index execution time: " << index_time.count() << "ms" << std::endl;
    std::cerr << "Matcher execution time: " << matcher_time.count() << "ms" << std::endl;
    std::cerr << "Overlap detection execution time: " << overlapper_time.count() << "ms" << std::endl;

    return 0;
}

void help(int32_t exit_code = 0)
{
    std::cerr <<
        R"(Usage: cudamapper [options ...] <query_sequences> <target_sequences>
     <sequences>
        Input file in FASTA/FASTQ format (can be compressed with gzip)
        containing sequences used for all-to-all overlapping
     options:
        -k, --kmer-size
            length of kmer to use for minimizers [15] (Max=)"
              << claragenomics::cudamapper::Index::maximum_kmer_size() << ")"
              << R"(
        -w, --window-size
            length of window to use for minimizers [15])"
              << R"(
        -i, --index-size
            length of batch size used for query [10000])"
              << R"(
        -t --target-index-size
            length of batch sized used for target [10000])"
              << std::endl;

    exit(exit_code);
}
